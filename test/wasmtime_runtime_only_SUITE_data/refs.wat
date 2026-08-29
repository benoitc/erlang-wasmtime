(module
  (table $t (export "t") 2 funcref)
  (elem (i32.const 0) $add)
  (func $add (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
  (func (export "id_ext") (param externref) (result externref) local.get 0))
