package deadline

import (
	"testing"
	"time"
)

func localTime(t *testing.T, text string) time.Time {
	t.Helper()
	var location *time.Location
	var err error
	location, err = time.LoadLocation("Europe/Amsterdam")
	if err != nil {
		t.Fatal(err)
	}
	var parsed time.Time
	parsed, err = time.ParseInLocation("2006-01-02 15:04:05", text, location)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func TestResolve(t *testing.T) {
	var cases []struct {
		expression string
		now        string
		want       string
	} = []struct{ expression, now, want string }{
		{"20h", "2026-08-29 10:15:30", "2026-08-30 06:15:30"},
		{"1d2h3m4s", "2026-08-29 10:15:30", "2026-08-30 12:18:34"},
		{"1d", "2026-03-28 12:00:00", "2026-03-29 13:00:00"},
		{"1:00", "2026-08-29 00:30:00", "2026-08-29 01:00:00"},
		{"01:00", "2026-08-29 01:00:00", "2026-08-30 01:00:00"},
		{"2:00 +2d", "2026-08-29 10:15:30", "2026-08-31 02:00:00"},
		{"2026-09-03 02:00", "2026-08-29 10:15:30", "2026-09-03 02:00:00"},
		{"2:00", "2026-03-29 00:30:00", "2026-03-30 02:00:00"},
	}
	for _, test := range cases {
		t.Run(test.expression+test.now, func(t *testing.T) {
			var got time.Time
			var err error
			got, err = Resolve(test.expression, localTime(t, test.now))
			if err != nil {
				t.Fatal(err)
			}
			if !got.Equal(localTime(t, test.want)) {
				t.Errorf("got %v, want %s", got, test.want)
			}
		})
	}
}

func TestRepeatedClockChoosesNextOccurrence(t *testing.T) {
	var location *time.Location = localTime(t, "2026-01-01 00:00:00").Location()
	var first time.Time = time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC).In(location)
	for _, offset := range []time.Duration{-time.Minute, 30 * time.Minute} {
		var got time.Time
		var err error
		got, err = Resolve("2:00", first.Add(offset))
		var want time.Time = first
		if offset > 0 {
			want = first.Add(time.Hour)
		}
		if err != nil || !got.Equal(want) {
			t.Errorf("offset %v: got %v, %v, want %v", offset, got, err, want)
		}
	}
	var got time.Time
	var err error
	got, err = Resolve("2026-10-25 02:00", first.Add(-time.Hour))
	if err != nil || !got.Equal(first) {
		t.Errorf("explicit repeated clock: %v, %v", got, err)
	}
}

func TestResolveRejectsInvalid(t *testing.T) {
	var now time.Time = localTime(t, "2026-03-28 12:00:00")
	for _, expression := range []string{"", "0h", "0d0h0m0s", "-1h", "1.5h", "4h1d", "1s2s", "1w", "24:00", "1:60", "2:00 +0d", "2:00 +4h", "1000000000d", "1h garbage", "2026-03-27 10:00", "2026-02-30 10:00", "2026-03-29 02:00", "2:00 +1d"} {
		var err error
		if _, err = Resolve(expression, now); err == nil {
			t.Errorf("accepted %q", expression)
		}
	}
}

func TestPresentation(t *testing.T) {
	var now time.Time = localTime(t, "2026-09-01 02:00:00")
	var cases []struct {
		seconds int64
		want    string
	} = []struct {
		seconds int64
		want    string
	}{{-1, "deadline passed"}, {0, "deadline passed"}, {1, "1s"}, {59, "59s"}, {60, "1m"}, {3599, "59m"}, {3600, "1h"}, {3660, "1h 1m"}, {183899, "2d 3h 4m"}}
	for _, test := range cases {
		var got string = Remaining(now.Add(time.Duration(test.seconds)*time.Second), now)
		if got != test.want {
			t.Errorf("%d: got %q", test.seconds, got)
		}
	}
	var got string = Format(now.Add(42*time.Second), now)
	if got != "2026-09-01 02:00:42 +0200 (in 42s)" {
		t.Error(got)
	}
}

func TestCalendarDaysAcrossMidnightTimezoneChanges(t *testing.T) {
	var location *time.Location
	var err error
	location, err = time.LoadLocation("America/Sao_Paulo")
	if err != nil {
		t.Fatal(err)
	}
	var now time.Time = time.Date(2018, 11, 3, 0, 30, 0, 0, location)
	var got time.Time
	got, err = Resolve("09:00 +1d", now)
	var want time.Time = time.Date(2018, 11, 4, 9, 0, 0, 0, location)
	if err != nil || !got.Equal(want) {
		t.Errorf("midnight DST transition: got %v, %v, want %v", got, err, want)
	}
	location, err = time.LoadLocation("Pacific/Apia")
	if err != nil {
		t.Fatal(err)
	}
	now = time.Date(2011, 12, 29, 8, 0, 0, 0, location)
	if _, err = Resolve("09:00 +1d", now); err == nil {
		t.Error("accepted a calendar date skipped by a timezone transition")
	}
	now = time.Date(2011, 12, 29, 10, 0, 0, 0, location)
	got, err = Resolve("09:00", now)
	want = time.Date(2011, 12, 31, 9, 0, 0, 0, location)
	if err != nil || !got.Equal(want) {
		t.Fatalf("clock across skipped calendar date: got %v, %v, want %v", got, err, want)
	}
}
