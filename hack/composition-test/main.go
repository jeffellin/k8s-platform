package main

import (
	"encoding/json"
	"fmt"
	"os"
	"text/template"

	"github.com/Masterminds/sprig/v3"
)

func main() {
	tb, _ := os.ReadFile(os.Args[1])
	ib, _ := os.ReadFile(os.Args[2])
	var in map[string]interface{}
	if err := json.Unmarshal(ib, &in); err != nil {
		panic(err)
	}
	t, err := template.New("c").Funcs(sprig.TxtFuncMap()).Option("missingkey=default").Parse(string(tb))
	if err != nil {
		fmt.Fprintln(os.Stderr, "PARSE ERROR:", err)
		os.Exit(3)
	}
	if err := t.Execute(os.Stdout, in); err != nil {
		fmt.Fprintln(os.Stderr, "EXEC ERROR:", err)
		os.Exit(4)
	}
}
