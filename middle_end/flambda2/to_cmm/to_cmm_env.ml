(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                        Guillaume Bury, OCamlPro                        *)
(*                                                                        *)
(*   Copyright 2019--2022 OCamlPro SAS                                    *)
(*   Copyright 2022 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-30-40-41-42"]

module C = Cmm_helpers
module Ece = Effects_and_coeffects

type cont =
  | Jump of
      { cont : Cmm.label;
        param_types : Cmm.machtype list
      }
  | Inline of
      { handler_params : Bound_parameters.t;
        handler_params_occurrences : Num_occurrences.t Variable.Map.t;
        handler_body : Flambda.Expr.t
      }

type extra_info =
  | Untag of Cmm.expression
  | Boxed_number

(* Delayed let-bindings (see the .mli) *)

type inline =
  | Do_not_inline
  | Inline_once
  | Duplicate

type binding =
  { order : int;
    inline : inline;
    effs : Ece.t;
    cmm_var : Backend_var.With_provenance.t;
    cmm_expr : Cmm.expression
  }

type stage =
  | Effect of Variable.t * binding
  | Coeffect_only of binding Variable.Map.t

type t =
  { (* Global information. This is computed once and remains valid for a whole
       compilation unit. *)
    offsets : Exported_offsets.t;
    (* Offsets for function and value slots. *)
    functions_info : Exported_code.t;
    (* Code and metadata of functions. *)
    (* Local information.

       This is relative to the flambda expression being currently translated,
       i.e. either the unit initialization code, or the body of a function. This
       information is reset when entering a new function. *)
    return_continuation : Continuation.t;
    (* The (non-exceptional) return continuation of the current context (used to
       determine which calls are tail-calls). *)
    exn_continuation : Continuation.t;
    (* The exception continuation of the current context (used to determine
       where to insert try-with blocks). *)
    vars : Cmm.expression Variable.Map.t;
    (* Cmm expressions (of the form [Cvar ...]) describing all Flambda variables
       in scope. *)
    vars_extra : extra_info Variable.Map.t;
    (* Extra information (see above) associated with Flambda variables. *)
    conts : cont Continuation.Map.t;
    (* Information about whether each continuation in scope should have its
       handler inlined, or else reached via a jump. *)
    exn_handlers : Continuation.Set.t;
    (* All continuations that act as exception handlers. *)
    exn_conts_extra_args : Backend_var.t list Continuation.Map.t;
    (* Mutable variables used for compiling the "extra arguments" to exception
       handlers. *)
    pures : binding Variable.Map.t;
    (* Pure let-bindings that can be inlined across _stages_ (see the .mli). *)
    stages : stage list (* Stages of let-bindings, most recent at the head. *)
  }

let create offsets functions_info ~return_continuation ~exn_continuation =
  { return_continuation;
    exn_continuation;
    offsets;
    functions_info;
    stages = [];
    pures = Variable.Map.empty;
    vars = Variable.Map.empty;
    vars_extra = Variable.Map.empty;
    conts = Continuation.Map.empty;
    exn_handlers = Continuation.Set.singleton exn_continuation;
    exn_conts_extra_args = Continuation.Map.empty
  }

let enter_function_body env ~return_continuation ~exn_continuation =
  create env.offsets env.functions_info ~return_continuation ~exn_continuation

let return_continuation env = env.return_continuation

let exn_continuation env = env.exn_continuation

let [@ocamlformat "disable"] print_inline ppf = function
  | Do_not_inline -> Format.fprintf ppf "do_not_inline"
  | Inline_once -> Format.fprintf ppf "inline_once"
  | Duplicate -> Format.fprintf ppf "duplicate"

let [@ocamlformat "disable"] print_binding ppf
    { order; inline; effs; cmm_var; cmm_expr; } =
  Format.fprintf ppf "@[<hov 1>(\
      @[<hov 1>(order@ %d)@]@ \
      @[<hov 1>(inline@ %a)@]@ \
      @[<hov 1>(effs@ %a)@]@ \
      @[<hov 1>(var@ %a)@]@ \
      @[<hov 1>(expr@ %a)@]\
    )@]"
    order
    print_inline inline
    Ece.print effs
    Backend_var.With_provenance.print cmm_var
    Printcmm.expression cmm_expr

(* Code and closures *)

let get_code_metadata env code_id =
  match Exported_code.find_exn env.functions_info code_id with
  | code_or_metadata -> Code_or_metadata.code_metadata code_or_metadata
  | exception Not_found ->
    Misc.fatal_errorf "To_cmm_env.get_code_metadata: code ID %a not bound"
      Code_id.print code_id

let exported_offsets t = t.offsets

(* Variables *)

let gen_variable v =
  let name = Variable.unique_name v in
  let v = Backend_var.create_local name in
  (* CR mshinwell: Fix [provenance] *)
  Backend_var.With_provenance.create ?provenance:None v

let add_variable env v v' =
  let v'' = Backend_var.With_provenance.var v' in
  let vars = Variable.Map.add v (C.var v'') env.vars in
  { env with vars }

let create_variable env v =
  if Variable.Map.mem v env.vars
  then
    Misc.fatal_errorf "Cannot rebind variable %a in To_cmm environment"
      Variable.print v;
  let v' = gen_variable v in
  let env = add_variable env v v' in
  env, v'

let create_variables env vs = List.fold_left_map create_variable env vs

let extra_info env v =
  match Variable.Map.find v env.vars_extra with
  | extra_info -> Some extra_info
  | exception Not_found -> None

(* Continuations *)

let get_cmm_continuation env k =
  match Continuation.Map.find k env.conts with
  | Jump { cont; _ } -> cont
  | Inline _ ->
    Misc.fatal_errorf "Continuation %a is registered for inlining, not a jump"
      Continuation.print k
  | exception Not_found ->
    Misc.fatal_errorf "Continuation %a not found in env" Continuation.print k

let get_continuation env k =
  match Continuation.Map.find k env.conts with
  | exception Not_found ->
    Misc.fatal_errorf "Could not find continuation %a in env during to_cmm"
      Continuation.print k
  | res -> res

let new_cmm_continuation = Lambda.next_raise_count

let add_jump_cont env k ~param_types =
  let cont = new_cmm_continuation () in
  let conts = Continuation.Map.add k (Jump { param_types; cont }) env.conts in
  cont, { env with conts }

let add_inline_cont env k ~handler_params ~handler_params_occurrences
    ~handler_body =
  let info =
    Inline { handler_params; handler_body; handler_params_occurrences }
  in
  let conts = Continuation.Map.add k info env.conts in
  { env with conts }

let add_exn_handler env k arity =
  let env =
    { env with exn_handlers = Continuation.Set.add k env.exn_handlers }
  in
  match Flambda_arity.to_list arity with
  | [] -> Misc.fatal_error "Exception handlers must have at least one parameter"
  | [_] -> env, []
  | _ :: extra_args ->
    let mut_vars =
      List.map
        (fun kind -> Backend_var.create_local "exn_extra_arg", kind)
        extra_args
    in
    let vars_only = List.map fst mut_vars in
    let exn_conts_extra_args =
      Continuation.Map.add k vars_only env.exn_conts_extra_args
    in
    { env with exn_conts_extra_args }, mut_vars

let is_exn_handler t cont = Continuation.Set.mem cont t.exn_handlers

let get_exn_extra_args env k =
  match Continuation.Map.find k env.exn_conts_extra_args with
  | exception Not_found -> []
  | extra_args -> extra_args

(* Variable binding (for potential inlining). Also see [To_cmm_effects]. *)

(*
let is_inlinable_box effs ~extra =
  (* [effs] is the effects and coeffects of some primitive operation, arising
     either from the primitive itself or its arguments. If this is a boxing
     operation (as indicated by [extra]) then we want to inline the box. However
     this involves moving the arguments, so they must be pure (or at most have
     generative effects, with no coeffects). *)
  match (effs : Ece.t), (extra : extra_info option) with
  | ((No_effects | Only_generative_effects _), No_coeffects), Some Boxed_number
    ->
    true
  | ( ( (No_effects | Only_generative_effects _ | Arbitrary_effects),
        (No_coeffects | Has_coeffects) ),
      (None | Some Boxed_number | Some (Untag _)) ) ->
    false
*)

let create_binding =
  let next_order = ref (-1) in
  fun ?extra env ~inline effs var cmm_expr ->
    let order =
      incr next_order;
      !next_order
    in
    let cmm_var = gen_variable var in
    let binding = { order; inline; effs; cmm_var; cmm_expr } in
    let cmm_expr = C.var (Backend_var.With_provenance.var cmm_var) in
    let env = { env with vars = Variable.Map.add var cmm_expr env.vars } in
    let env =
      match extra with
      | None -> env
      | Some info ->
        { env with vars_extra = Variable.Map.add var info env.vars_extra }
    in
    env, binding

let bind_variable ?extra env var
    ~effects_and_coeffects_of_defining_expr:effs
    ~inline ~defining_expr =
  let env, binding =
    create_binding ?extra env ~inline effs var defining_expr
  in
  match inline with
  | Duplicate ->
    (* check that the effects and coeffects allow the expression to be duplicated
       without changing semantics *)
    begin match (effs : Ece.t) with
      | (Only_generative_effects Immutable | No_effects), No_coeffects, _ -> ()
      | (No_effects | Arbitrary_effects | Only_generative_effects (Immutable | Mutable | Immutable_unique)),
        (No_coeffects | Has_coeffects), _ ->
        Misc.fatal_errorf
          "Incorect effects and/or coeffects for a duplicated binding: %a"
          print_binding binding
    end;
    (* We bind duplicated bindings as pure so that they are inlined/subtituted
       as much as possible. This is legal because of the checkl on effects and
       co-effects above.

       CR: this allows to move allocations past function calls (and other
       effectful expressions), which can break some allocation-counting tests. *)
    { env with pures = Variable.Map.add var binding env.pures }
  | Inline_once | Do_not_inline ->
    begin match To_cmm_effects.classify_by_effects_and_coeffects effs with
    | Pure -> { env with pures = Variable.Map.add var binding env.pures }
    | Effect -> { env with stages = Effect (var, binding) :: env.stages }
    | Coeffect_only ->
      let stages =
        match env.stages with
        | Coeffect_only bindings :: stages ->
          (* Multiple coeffect-only bindings may be accumulated in the same
             stage. *)
          Coeffect_only (Variable.Map.add var binding bindings) :: stages
        | [] | Effect _ :: _ ->
          Coeffect_only (Variable.Map.singleton var binding) :: env.stages
      in
      { env with stages }
    end

let bind_let_variable ?extra env var
    ~effects_and_coeffects_of_defining_expr
    ~inline ~defining_expr
  =
  match (inline : To_cmm_effects.let_binding_classification) with
  | Drop_defining_expr -> env
  | Regular ->
    bind_variable ?extra env var ~effects_and_coeffects_of_defining_expr
      ~defining_expr ~inline:Do_not_inline
  | May_inline_once ->
    bind_variable ?extra env var ~effects_and_coeffects_of_defining_expr
      ~defining_expr ~inline:Inline_once
  | Inline_and_duplicate ->
    bind_variable ?extra env var ~effects_and_coeffects_of_defining_expr
      ~defining_expr ~inline:Duplicate


(* Variable lookup (for potential inlining) *)

let will_inline env binding = binding.cmm_expr, env, binding.effs

let will_not_inline env binding =
  C.var (Backend_var.With_provenance.var binding.cmm_var), env, Ece.pure_duplicatable

let will_not_inline_var env v =
  (* This is like [will_not_inline] but is used in the case where no delayed
     [binding] is available. A preallocated [Cvar] expression will be used. *)
  match Variable.Map.find v env.vars with
  | exception Not_found ->
    Misc.fatal_errorf "Variable %a not found in env" Variable.print v
  | e -> e, env, Ece.pure_duplicatable

let get_variable ~inline_once env var =
  match Variable.Map.find var env.pures with
  | binding ->
    begin match binding.inline with
      | Do_not_inline ->
        will_not_inline env binding
      | Duplicate ->
        (* duplicated bindings need to stay in the map of pure bindings *)
        will_inline env binding
      | Inline_once ->
        if inline_once then
          (* Pure bindings may be inlined at most once. *)
          let pures = Variable.Map.remove var env.pures in
          will_inline { env with pures } binding
        else
          will_not_inline env binding
    end
  | exception Not_found -> (
    match env.stages with
    | [] -> will_not_inline_var env var
    | Effect (var_from_stage, binding) :: prev_stages ->
      (* In this case [var_from_stage] corresponds to an effectful binding
         forming the most recent stage. We also know that [var] doesn't have an
         available pure defining expression (either because that expression
         isn't pure, or because the corresponding binding has already been
         flushed). As such, we can't move the defining expression for [var] past
         that of [var_from_stage], in the case where these variables are
         different. However if these two variables are in fact the same, we can
         consider inlining the defining expression. *)
      if not (Variable.equal var var_from_stage)
      then will_not_inline_var env var
      else begin match binding.inline with
        | Do_not_inline -> will_not_inline env binding
        | Inline_once ->
          if inline_once
          then will_inline { env with stages = prev_stages } binding
          else will_not_inline env binding
        | Duplicate -> assert false
      end
    | Coeffect_only coeffects :: prev_stages -> (
      (* Here we see if [var] has a coeffect-only defining expression on the
         most recent stage. If so, then we can commute it with any other
         expression on the stage, since they all only have coeffects. The
         defining expression for [var] may then be considered for inlining. *)
      match Variable.Map.find var coeffects with
      | exception Not_found -> will_not_inline_var env var
      | binding ->
        begin match binding.inline with
          | Do_not_inline -> will_not_inline env binding
          | Duplicate -> assert false
          | Inline_once ->
            if inline_once then
              let coeffects = Variable.Map.remove var coeffects in
              let env =
                if Variable.Map.is_empty coeffects
                then { env with stages = prev_stages }
                else { env with stages = Coeffect_only coeffects :: prev_stages }
              in
              will_inline env binding
            else
              will_not_inline env binding
        end))

let find_variable = get_variable ~inline_once:false
let inline_variable = get_variable ~inline_once:true

(* Flushing delayed bindings *)

(* Map on integers in descending order *)
module M = Map.Make (struct
  type t = int

  let compare x y = compare y x
end)

let order_add b acc = M.add b.order b acc

let order_add_map m acc =
  Variable.Map.fold (fun _ b acc -> order_add b acc) m acc

let flush_delayed_lets ?(entering_loop = false) env =
  (* Generate a wrapper function to introduce the delayed let-bindings. *)
  let flush pures stages e =
    let order_map = order_add_map pures M.empty in
    let order_map =
      List.fold_left
        (fun acc -> function
          | Effect (_, b) -> order_add b acc
          | Coeffect_only m -> order_add_map m acc)
        order_map stages
    in
    M.fold
      (fun _ b acc ->
         match b.inline with
         (* We drop bindings that have been marked as being inlined and duplicated. *)
         | Duplicate ->
           Misc.fatal_errorf "Duplicated binding should never be flushed"
         | Inline_once | Do_not_inline ->
           Cmm_helpers.letin b.cmm_var ~defining_expr:b.cmm_expr ~body:acc)
      order_map e
  in
  (* Unless entering a loop, only pure bindings that definitely cannot be
     inlined are flushed now. The remainder are preserved, ensuring that the
     corresponding expressions are sunk down as far as possible. *)
  (* CR-someday mshinwell: work out a criterion for allowing substitutions into
     loops. *)
  let pures_to_keep, pures_to_flush =
    if entering_loop
    then
      Variable.Map.partition
        (fun _ binding ->
           match binding.inline with
           | Duplicate -> true
           | Inline_once | Do_not_inline -> false)
        env.pures
    else
      Variable.Map.partition
        (fun _ binding ->
          match binding.inline with
          | Do_not_inline -> false
          | Inline_once | Duplicate -> true)
        env.pures
  in
  let flush e = flush pures_to_flush env.stages e in
  flush, { env with stages = []; pures = pures_to_keep }

