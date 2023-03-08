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

val apply_renaming : t -> Renaming.t -> t

val ids_for_export : t -> Ids_for_export.t
