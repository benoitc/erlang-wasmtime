(component
  (core func $ret (canon task.return (result u32)))
  (core module $m
    (import "" "task.return" (func $ret (param i32)))
    (func (export "double") (param i32) (result i32)
      (call $ret (i32.mul (local.get 0) (i32.const 2)))
      (i32.const 0))
    (func (export "cb") (param i32 i32 i32) (result i32) unreachable))
  (core instance $i (instantiate $m
    (with "" (instance (export "task.return" (func $ret))))))
  (type $t (func async (param "x" u32) (result u32)))
  (func (export "double") (type $t)
    (canon lift (core func $i "double") async (callback (core func $i "cb")))))
