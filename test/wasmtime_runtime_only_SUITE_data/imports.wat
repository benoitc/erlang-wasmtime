(module
  (import "env" "twice" (func $twice (param i32) (result i32)))
  (func (export "run") (param i32) (result i32)
    local.get 0 call $twice))
