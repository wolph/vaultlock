package vault

import (
	"crypto/sha256"
	"encoding/json"
)

type adoptHashRecord struct {
	fingerprint [32]byte
	payload     string
}

type adoptHashCache map[adoptCopyIdentity]adoptHashRecord

func adoptMetadataFingerprint(metadata adoptMetadata) ([32]byte, error) {
	var encoded []byte
	var err error
	encoded, err = json.Marshal(metadata)
	if err != nil {
		return [32]byte{}, err
	}
	return sha256.Sum256(encoded), nil
}

func (p *adoptProgress) cachedPayload(metadata adoptMetadata, fingerprint [32]byte) (string, bool) {
	if p == nil || p.hashCache == nil {
		return "", false
	}
	var record adoptHashRecord
	var found bool
	record, found = p.hashCache[adoptCopyIdentity{Device: metadata.Device, Inode: metadata.Inode}]
	return record.payload, found && record.fingerprint == fingerprint
}

func (p *adoptProgress) rememberPayload(metadata adoptMetadata, fingerprint [32]byte, payload string) {
	if p != nil && p.hashCache != nil {
		p.hashCache[adoptCopyIdentity{Device: metadata.Device, Inode: metadata.Inode}] = adoptHashRecord{fingerprint: fingerprint, payload: payload}
	}
}
