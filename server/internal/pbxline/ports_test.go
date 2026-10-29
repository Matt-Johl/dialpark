package pbxline

import (
	"strings"
	"testing"
)

func TestParsePortRange(t *testing.T) {
	for _, tc := range []struct {
		in      string
		want    PortRange
		wantErr string
	}{
		{"", PortRange{}, ""},
		{"5062-5099", PortRange{5062, 5099}, ""},
		{" 5062 - 5062 ", PortRange{5062, 5062}, ""},
		{"5062", PortRange{}, "first-last"},
		{"5099-5062", PortRange{}, "before first"},
		{"0-10", PortRange{}, "1-65535"},
		{"65000-70000", PortRange{}, "1-65535"},
		{"a-b", PortRange{}, "1-65535"},
		{"5000-6000", PortRange{}, "more than 256"},
	} {
		got, err := ParsePortRange(tc.in)
		if tc.wantErr != "" {
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("ParsePortRange(%q) err = %v, want one mentioning %q", tc.in, err, tc.wantErr)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("ParsePortRange(%q) = %v, %v; want %v", tc.in, got, err, tc.want)
		}
	}
}

func TestPortRangeShape(t *testing.T) {
	var none PortRange
	if none.Len() != 0 || none.Contains(0) || none.Contains(5062) || none.String() != "" {
		t.Errorf("the zero range is no ports: Len %d Contains(5062) %v String %q", none.Len(), none.Contains(5062), none.String())
	}
	r := PortRange{5062, 5065}
	if r.Len() != 4 || r.String() != "5062-5065" {
		t.Errorf("Len %d String %q", r.Len(), r.String())
	}
	for p, want := range map[int]bool{5061: false, 5062: true, 5065: true, 5066: false, 0: false} {
		if r.Contains(p) != want {
			t.Errorf("Contains(%d) = %v", p, !want)
		}
	}
}
