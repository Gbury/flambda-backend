(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Guillaume Bury, OCamlPro SAS                          *)
(*                                                                        *)
(*   Copyright 2022 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

type t = Classic_unbox_number_in_cmm of Flambda_kind.Boxable_number.t

let ids_for_export t =
  match t with Classic_unbox_number_in_cmm _ -> Ids_for_export.empty

let apply_renaming t _renaming =
  match t with Classic_unbox_number_in_cmm _ -> t
