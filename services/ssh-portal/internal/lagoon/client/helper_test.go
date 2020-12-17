package client

// StructToVarMap exposes the private client.structToVarMap for tests.
func StructToVarMap(varStruct interface{}) (map[string]interface{}, error) {
	return structToVarMap(varStruct)
}
