let foo b x' =
  let () = Sys.opaque_identity () in
  let x = x' in
  let v =
    if b then
      let y' = 42. *. x in
      let y = y' in
      let[@inline] machin () =
        x +. y
      in
      let () = Sys.opaque_identity () in
      Ok machin
    else
      Error x
  in
  match v with
  | Ok f -> f ()
  | Error x -> x
