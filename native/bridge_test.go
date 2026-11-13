package main

import "testing"

func TestTargetValidation(t *testing.T) {
	for _, value := range []string{"http://100.64.0.1:8188", "https://[fd7a:115c:a1e0::1]:8188"} {
		if _, err := validateTarget(value); err != nil {
			t.Errorf("reject %s: %v", value, err)
		}
	}
	for _, value := range []string{"http://example.com:8188", "file:///etc/passwd", "http://user:pass@100.64.0.1:8188", "http://100.64.0.1:0", "http://100.64.0.1:8188/x", "http://100.64.0.1:8188?x=1", "http://0.0.0.0:8188"} {
		if _, err := validateTarget(value); err == nil {
			t.Errorf("accepted invalid target %s", value)
		}
	}
}
