(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2019 OCamlPro SAS                                    *)
(*   Copyright 2014--2019 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-30-40-41-42"]

type t =
  { simplified_named : Simplified_named.t Or_invalid.t;
    try_reify : bool;
    dacc : Downwards_acc.t
  }

let print ppf { simplified_named; try_reify; dacc = _; } =
  Format.fprintf ppf "@[<hov 1>(\
      @[<hov 1>(try_reify@ %b)@]@ \
      @[<hov 1>(simplified_named@ %a)@]\
    )@]"
    try_reify (Or_invalid.print Simplified_named.print) simplified_named

let create named ~try_reify dacc =
  { simplified_named = Ok (Simplified_named.create named); try_reify; dacc }

let create_simplified simplified_named ~try_reify dacc =
  { simplified_named = Ok simplified_named; try_reify; dacc }

let create_invalid dacc =
  { simplified_named = Invalid; try_reify = false; dacc }

let create_unit dacc ~result_var ~original_term =
  (* CR gbury: would it make sense to have a Flambda2_types.unit instead of this
     ? *)
  let ty = Flambda2_types.this_tagged_immediate Targetint_31_63.zero in
  let dacc = Downwards_acc.add_variable dacc result_var ty in
  create original_term ~try_reify:false dacc

let create_unknown dacc ~result_var kind ~original_term =
  let ty = Flambda2_types.unknown kind in
  let dacc = Downwards_acc.add_variable dacc result_var ty in
  create original_term ~try_reify:false dacc

let with_dacc t dacc = { t with dacc }
