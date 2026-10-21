package vault

// Provenance is OS-managed tracking state. Original bytes are archived before
// adoption mutates data. All portable attributes remain part of verification.
func portableAdoptXattrs(attributes []adoptXattr) []adoptXattr {
	var result []adoptXattr
	var attribute adoptXattr
	for _, attribute = range attributes {
		if attribute.Name != "com.apple.provenance" {
			result = append(result, attribute)
		}
	}
	return result
}
