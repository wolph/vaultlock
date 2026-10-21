// Package deadline resolves local calendar deadlines and elapsed durations.
package deadline

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata" // Keep timezone data available in standalone installations.
)

var (
	durationPattern *regexp.Regexp = regexp.MustCompile(`^([0-9]{1,9}d)?([0-9]{1,9}h)?([0-9]{1,9}m)?([0-9]{1,9}s)?$`)
	clockPattern    *regexp.Regexp = regexp.MustCompile(`^([0-9]{1,2}):([0-9]{2})$`)
	combinedPattern *regexp.Regexp = regexp.MustCompile(`^([0-9]{1,2}:[0-9]{2})[[:space:]]+\+([0-9]{1,9})d$`)
	absolutePattern *regexp.Regexp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$`)
	errInvalid      error          = errors.New("invalid or past deadline")
)

// Resolve accepts d/h/m/s durations, local HH:MM clocks, HH:MM +Nd,
// and local YYYY-MM-DD HH:MM timestamps. Durations use elapsed seconds.
func Resolve(expression string, now time.Time) (time.Time, error) {
	var target time.Time
	var combined []string = combinedPattern.FindStringSubmatch(expression)
	if absolutePattern.MatchString(expression) {
		var candidates []time.Time = localMinutes(expression, now.Location())
		if len(candidates) > 0 {
			target = candidates[0]
		}
	} else if combined != nil {
		var clock string
		var err error
		clock, err = normaliseClock(combined[1])
		if err != nil {
			return time.Time{}, err
		}
		var days int
		days, _ = strconv.Atoi(combined[2])
		if days == 0 {
			return time.Time{}, errInvalid
		}
		var date string = calendarDate(now, days)
		var candidates []time.Time = localMinutes(date+" "+clock, now.Location())
		if len(candidates) > 0 {
			target = candidates[0]
		}
	} else if clockPattern.MatchString(expression) {
		return resolveClock(expression, now)
	} else {
		var match []string = durationPattern.FindStringSubmatch(expression)
		if expression == "" || match == nil {
			return time.Time{}, errInvalid
		}
		var seconds int64
		var units []int64 = []int64{86400, 3600, 60, 1}
		for index, unit := range units {
			if match[index+1] == "" {
				continue
			}
			var value int64
			value, _ = strconv.ParseInt(match[index+1][:len(match[index+1])-1], 10, 64)
			seconds += value * unit
		}
		if seconds == 0 || now.Unix() > (1<<63-1)-seconds {
			return time.Time{}, errInvalid
		}
		target = time.Unix(now.Unix()+seconds, 0).In(now.Location())
	}
	if target.IsZero() || !target.After(now) {
		return time.Time{}, errInvalid
	}
	return target, nil
}

func normaliseClock(clock string) (string, error) {
	var match []string = clockPattern.FindStringSubmatch(clock)
	if match == nil {
		return "", errInvalid
	}
	var hour int
	hour, _ = strconv.Atoi(match[1])
	var minute int
	minute, _ = strconv.Atoi(match[2])
	if hour > 23 || minute > 59 {
		return "", errInvalid
	}
	return fmt.Sprintf("%02d:%02d", hour, minute), nil
}

func resolveClock(expression string, now time.Time) (time.Time, error) {
	var clock string
	var err error
	clock, err = normaliseClock(expression)
	if err != nil {
		return time.Time{}, err
	}
	for day := 0; day < 3; day++ {
		var date string = calendarDate(now, day)
		for _, candidate := range localMinutes(date+" "+clock, now.Location()) {
			if candidate.After(now) {
				return candidate, nil
			}
		}
	}
	return time.Time{}, errInvalid
}

// Calendar arithmetic uses the date alone so midnight timezone changes cannot
// normalise an intermediate local clock into the previous calendar date.
func calendarDate(now time.Time, days int) string {
	var year int
	var month time.Month
	var day int
	year, month, day = now.Date()
	var date time.Time = time.Date(year, month, day, 0, 0, 0, 0, time.UTC)
	return date.AddDate(0, 0, days).Format("2006-01-02")
}

// localMinutes enumerates both occurrences of a repeated local minute.
// Round-tripping also rejects normalised dates and skipped DST minutes.
func localMinutes(text string, location *time.Location) []time.Time {
	var wall time.Time
	var err error
	wall, err = time.Parse("2006-01-02 15:04", text)
	if err != nil {
		return nil
	}
	var offsets map[int]bool = make(map[int]bool)
	for hours := -48; hours <= 48; hours += 12 {
		var offset int
		_, offset = wall.Add(time.Duration(hours) * time.Hour).In(location).Zone()
		offsets[offset] = true
	}
	var candidates []time.Time
	for offset := range offsets {
		var candidate time.Time = wall.Add(-time.Duration(offset) * time.Second).In(location)
		if candidate.Format("2006-01-02 15:04") == text {
			candidates = append(candidates, candidate)
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].Before(candidates[j]) })
	return candidates
}

// Remaining formats positive elapsed seconds, dropping seconds above one minute.
func Remaining(target, now time.Time) string {
	var seconds int64 = target.Unix() - now.Unix()
	if seconds <= 0 {
		return "deadline passed"
	}
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	var parts []string
	for _, unit := range []struct {
		seconds int64
		suffix  string
	}{{86400, "d"}, {3600, "h"}, {60, "m"}} {
		var value int64 = seconds / unit.seconds
		if value > 0 {
			parts = append(parts, fmt.Sprintf("%d%s", value, unit.suffix))
		}
		seconds %= unit.seconds
	}
	return strings.Join(parts, " ")
}

// Format includes the target's local UTC offset and remaining elapsed time.
func Format(target, now time.Time) string {
	var remaining string = Remaining(target, now)
	if remaining != "deadline passed" {
		remaining = "in " + remaining
	}
	return fmt.Sprintf("%s (%s)", target.Format("2006-01-02 15:04:05 -0700"), remaining)
}
