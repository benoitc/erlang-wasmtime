(module
  (memory (export "memory") 1)
  (data (i32.const 0) "hello")
  (func (export "add") (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.add)
  (func (export "loop") (loop br 0))
  (func (export "boom") unreachable)
  (func (export "load") (param i32) (result i32)
    local.get 0 i32.load8_u))
