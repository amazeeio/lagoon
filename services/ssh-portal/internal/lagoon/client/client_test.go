package client_test

import (
	"reflect"
	"testing"

	"github.com/smlx/lagoon/services/ssh-portal/internal/lagoon/client"
)

type testStruct0 struct {
	Foo  string `json:"foo"`
	Bar  uint   `json:"bar"`
	Baz  string `json:"baz,omitempty"`
	Quux uint   `json:"quux,omitempty"`
}

func TestStructToVarMap(t *testing.T) {
	var testCases = map[string]struct {
		input  testStruct0
		expect map[string]interface{}
	}{
		"simple struct": {
			input: testStruct0{
				Foo: "abc",
				Bar: 8,
			},
			expect: map[string]interface{}{
				"foo": "abc",
				"bar": float64(8),
			},
		},
		"keep zero values": {
			input: testStruct0{
				Foo: "abc",
				Bar: 0,
			},
			expect: map[string]interface{}{
				"foo": "abc",
				"bar": float64(0),
			},
		},
		"omit zero values": {
			input: testStruct0{
				Foo:  "abc",
				Bar:  0,
				Baz:  "",
				Quux: 0,
			},
			expect: map[string]interface{}{
				"foo": "abc",
				"bar": float64(0),
			},
		},
		"keep non-zero values": {
			input: testStruct0{
				Foo:  "abc",
				Bar:  0,
				Baz:  "hi",
				Quux: 9,
			},
			expect: map[string]interface{}{
				"foo":  "abc",
				"bar":  float64(0),
				"baz":  "hi",
				"quux": float64(9),
			},
		},
	}
	for name, tc := range testCases {
		t.Run(name, func(tt *testing.T) {
			vars, err := client.StructToVarMap(&tc.input)
			if err != nil {
				tt.Error(err)
			}
			if !reflect.DeepEqual(vars, tc.expect) {
				tt.Logf("result:\n%s\nexpected:\n%s", vars, tc.expect)
				tt.Errorf("result does not match expected")
			}
		})
	}
}
