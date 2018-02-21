(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

module B = Buffer
module H = Hhbc_ast
module A = Ast
module SS = String_sequence
module SU = Hhbc_string_utils
module SN = Naming_special_names
module ULS = Unique_list_string
open H

(* Generic helpers *)
let sep pieces = String.concat " " pieces

let indent_text = "  "

let string_of_optional_value f v =
  Option.value_map v
    ~default:""
    ~f:(fun s -> " " ^ (f s))

let string_of_class_id id =
  SU.quote_string (Hhbc_id.Class.to_raw_string id)
let string_of_function_id id =
  SU.quote_string (Hhbc_id.Function.to_raw_string id)
let string_of_method_id id =
  SU.quote_string (Hhbc_id.Method.to_raw_string id)
let string_of_const_id id =
  SU.quote_string (Hhbc_id.Const.to_raw_string id)
let string_of_prop_id id =
  SU.quote_string (Hhbc_id.Prop.to_raw_string id)
let string_of_class_num id =
  string_of_int id
let string_of_function_num id =
  string_of_int id
let string_of_typedef_num id =
  string_of_int id
let string_of_pos pos =
  let line_begin, line_end, col_begin, col_end = Pos.info_pos_extended pos in
  Printf.sprintf "%d:%d,%d:%d" line_begin col_begin line_end col_end
let string_of_span (line_begin, line_end) =
  Printf.sprintf "(%d,%d)" line_begin line_end

(* Naming convention for functions below:
 *   string_of_X converts an X to a string
 *   add_X takes a buffer and an X, and appends to the buffer
 *)
let string_of_basic instruction =
  match instruction with
    | Nop         -> "Nop"
    | EntryNop    -> "EntryNop"
    | PopC        -> "PopC"
    | PopV        -> "PopV"
    | PopR        -> "PopR"
    | PopU        -> "PopU"
    | Dup         -> "Dup"
    | Box         -> "Box"
    | Unbox       -> "Unbox"
    | BoxR        -> "BoxR"
    | UnboxR      -> "UnboxR"
    | UnboxRNop   -> "UnboxRNop"
    | RGetCNop    -> "RGetCNop"

let string_of_list_of_shape_fields sl =
  String.concat " " @@ List.map SU.quote_string sl

let string_of_stack_index si = string_of_int si

let string_of_classref id = string_of_int id

let string_of_adata_id id = "@" ^ id

let string_of_param_id x =
  match x with
  | Param_unnamed i -> string_of_int i
  | Param_named s -> s

let string_of_param_num i = string_of_int i

let string_of_local_id x =
  match x with
  | Local.Unnamed i -> "_" ^ (string_of_int i)
  | Local.Named s -> s

let string_of_lit_const instruction =
  match instruction with
    | Null        -> "Null"
    | Int i       -> sep ["Int"; Int64.to_string i]
    | String str  -> sep ["String"; SU.quote_string str]
    | True        -> "True"
    | False       -> "False"
    | Double d    -> sep ["Double"; d]
    | AddElemC          -> "AddElemC"
    | AddNewElemC       -> "AddNewElemC"
    | Array id          -> sep ["Array"; string_of_adata_id id]
    | Dict id           -> sep ["Dict"; string_of_adata_id id]
    | Keyset id         -> sep ["Keyset"; string_of_adata_id id]
    | Vec id            -> sep ["Vec"; string_of_adata_id id]
    | TypedValue _tv    -> failwith "string_of_lit_const: TypedValue"
    | ColFromArray t    -> sep ["ColFromArray"; CollectionType.to_string t]
    | NewCol t          -> sep ["NewCol"; CollectionType.to_string t]
    | NewDictArray i    -> sep ["NewDictArray"; string_of_int i]
    | NewKeysetArray i  -> sep ["NewKeysetArray"; string_of_int i]
    | NewVecArray i     -> sep ["NewVecArray"; string_of_int i]
    | NewVArray i       -> sep ["NewVArray"; string_of_int i]
    | NewDArray i       -> sep ["NewDArray"; string_of_int i]
    | NewMixedArray i   -> sep ["NewMixedArray"; string_of_int i]
    | NewPackedArray i  -> sep ["NewPackedArray"; string_of_int i]
    | NewStructArray l  ->
      sep ["NewStructArray"; "<" ^ string_of_list_of_shape_fields l ^ ">"]
    | NewStructDArray l  ->
      sep ["NewStructDArray"; "<" ^ string_of_list_of_shape_fields l ^ ">"]
    | NewStructDict l  ->
      sep ["NewStructDict"; "<" ^ string_of_list_of_shape_fields l ^ ">"]
    | NewPair -> "NewPair"
    | ClsCns (cnsid, cr) ->
      sep ["ClsCns"; string_of_const_id cnsid; string_of_classref cr]
    | ClsCnsD (cnsid, cid) ->
      sep ["ClsCnsD"; string_of_const_id cnsid; string_of_class_id cid]
    | File -> "File"
    | Dir -> "Dir"
    | NYI text -> nyi ^ ": " ^ text
    | NullUninit -> "NullUninit"
    | AddElemV -> "AddElemV"
    | AddNewElemV -> "AddNewElemV"
    | Method -> "Method"
    | NewArray n -> sep ["NewArray"; string_of_int n]
    | NewLikeArrayL (id, n) ->
      sep ["NewLikeArrayL"; string_of_local_id id; string_of_int n]
    | Cns cnsid -> sep ["Cns"; string_of_const_id cnsid]
    | CnsE cnsid -> sep ["CnsE"; string_of_const_id cnsid]
    | CnsU (id1, id2) ->
      sep ["CnsU"; string_of_const_id id1; SU.quote_string id2]

let string_of_operator instruction =
  match instruction with
    | Concat -> "Concat"
    | Abs -> "Abs"
    | Add -> "Add"
    | Sub -> "Sub"
    | Mul -> "Mul"
    | AddO -> "AddO"
    | SubO -> "SubO"
    | MulO -> "MulO"
    | Div -> "Div"
    | Mod -> "Mod"
    | Pow -> "Pow"
    | Sqrt -> "Sqrt"
    | Xor -> "Xor"
    | Not -> "Not"
    | Same -> "Same"
    | NSame -> "NSame"
    | Eq -> "Eq"
    | Neq -> "Neq"
    | Lt -> "Lt"
    | Lte -> "Lte"
    | Gt -> "Gt"
    | Gte -> "Gte"
    | Cmp -> "Cmp"
    | BitAnd -> "BitAnd"
    | BitOr -> "BitOr"
    | BitXor -> "BitXor"
    | BitNot -> "BitNot"
    | Shl -> "Shl"
    | Shr -> "Shr"
    | Floor -> "Floor"
    | Ceil -> "Ceil"
    | CastBool -> "CastBool"
    | CastInt -> "CastInt"
    | CastDouble -> "CastDouble"
    | CastString -> "CastString"
    | CastArray -> "CastArray"
    | CastObject -> "CastObject"
    | CastVec -> "CastVec"
    | CastDict -> "CastDict"
    | CastKeyset -> "CastKeyset"
    | CastVArray -> "CastVArray"
    | CastDArray -> "CastDArray"
    | InstanceOf -> "InstanceOf"
    | InstanceOfD id -> sep ["InstanceOfD"; string_of_class_id id]
    | Print -> "Print"
    | Clone -> "Clone"
    | H.Exit -> "Exit"
    | Fatal op -> sep ["Fatal"; FatalOp.to_string op]

let string_of_get x =
  match x with
  | CGetL id -> sep ["CGetL"; string_of_local_id id]
  | CGetQuietL id -> sep ["CGetQuietL"; string_of_local_id id]
  | CGetL2 id -> sep ["CGetL2"; string_of_local_id id]
  | CUGetL id -> sep ["CUGetL"; string_of_local_id id]
  | PushL id -> sep ["PushL"; string_of_local_id id]
  | CGetN -> "CGetN"
  | CGetQuietN -> "CGetQuietN"
  | CGetG -> "CGetG"
  | CGetQuietG -> "CGetQuietG"
  | CGetS id -> sep ["CGetS"; string_of_classref id]
  | VGetN -> "VGetN"
  | VGetG -> "VGetG"
  | VGetS id -> sep ["VGetS"; string_of_classref id]
  | VGetL id -> sep ["VGetL"; string_of_local_id id]
  | ClsRefGetL (id, cr) ->
    sep ["ClsRefGetL"; string_of_local_id id; string_of_int cr]
  | ClsRefGetC cr ->
    sep ["ClsRefGetC"; string_of_int cr]

let string_of_member_key mk =
  let open MemberKey in
  match mk with
  | EC i -> "EC:" ^ string_of_stack_index i
  | EL id -> "EL:" ^ string_of_local_id id
  | ET str -> "ET:" ^ SU.quote_string str
  | EI i -> "EI:" ^ Int64.to_string i
  | PC i -> "PC:" ^ string_of_stack_index i
  | PL id -> "PL:" ^ string_of_local_id id
  | PT id -> "PT:" ^ string_of_prop_id id
  | QT id -> "QT:" ^ string_of_prop_id id
  | W -> "W"

let string_of_fpasshint h =
  match h with
  | Any -> "Any"
  | Cell -> "Cell"
  | Ref -> "Ref"

let string_of_eq_op op =
  match op with
  | PlusEqual -> "PlusEqual"
  | MinusEqual -> "MinusEqual"
  | MulEqual -> "MulEqual"
  | ConcatEqual -> "ConcatEqual"
  | DivEqual -> "DivEqual"
  | PowEqual -> "PowEqual"
  | ModEqual -> "ModEqual"
  | AndEqual -> "AndEqual"
  | OrEqual -> "OrEqual"
  | XorEqual -> "XorEqual"
  | SlEqual -> "SlEqual"
  | SrEqual -> "SrEqual"
  | PlusEqualO -> "PlusEqualO"
  | MinusEqualO -> "MinusEqualO"
  | MulEqualO -> "MulEqualO"

let string_of_incdec_op op =
  match op with
  | PreInc -> "PreInc"
  | PostInc -> "PostInc"
  | PreDec -> "PreDec"
  | PostDec -> "PostDec"
  | PreIncO -> "PreIncO"
  | PostIncO -> "PostIncO"
  | PreDecO -> "PreDecO"
  | PostDecO -> "PostDecO"

let string_of_istype_op op =
  match op with
  | OpNull -> "Null"
  | OpBool -> "Bool"
  | OpInt -> "Int"
  | OpDbl -> "Dbl"
  | OpStr -> "Str"
  | OpArr -> "Arr"
  | OpObj -> "Obj"
  | OpRes -> "Res"
  | OpScalar -> "Scalar"
  | OpVec -> "Vec"
  | OpDict -> "Dict"
  | OpKeyset -> "Keyset"
  | OpArrLike -> "ArrLike"
  | OpVArray -> "VArray"
  | OpDArray -> "DArray"

let string_of_initprop_op op =
  match op with
  | NonStatic -> "NonStatic"
  | Static -> "Static"

let string_of_mutator x =
  match x with
  | SetL id -> sep ["SetL"; string_of_local_id id]
  | PopL id -> sep ["PopL"; string_of_local_id id]
  | SetN -> "SetN"
  | SetG -> "SetG"
  | SetS id -> sep ["SetS"; string_of_classref id]
  | SetOpL (id, op) ->
    sep ["SetOpL"; string_of_local_id id; string_of_eq_op op]
  | SetOpN op -> sep ["SetOpN"; string_of_eq_op op]
  | SetOpG op -> sep ["SetOpG"; string_of_eq_op op]
  | SetOpS (op, id) -> sep ["SetOpS"; string_of_eq_op op; string_of_classref id]
  | IncDecL (id, op) ->
    sep ["IncDecL"; string_of_local_id id; string_of_incdec_op op]
  | IncDecN op -> sep ["IncDecN"; string_of_incdec_op op]
  | IncDecG op -> sep ["IncDecG"; string_of_incdec_op op]
  | IncDecS (op, id) ->
    sep ["IncDecS"; string_of_incdec_op op; string_of_classref id]
  | BindL id -> sep ["BindL"; string_of_local_id id]
  | BindN -> "BindN"
  | BindG -> "BindG"
  | BindS id -> sep ["BindS"; string_of_classref id]
  | UnsetL id -> sep ["UnsetL"; string_of_local_id id]
  | UnsetN -> "UnsetN"
  | UnsetG -> "UnsetG"
  | CheckProp id -> sep ["CheckProp"; string_of_prop_id id]
  | InitProp (id, op) -> sep ["InitProp"; string_of_prop_id id;
      string_of_initprop_op op]

let string_of_label label =
  match label with
    | Label.Regular id -> "L" ^ (string_of_int id)
    | Label.Catch id -> "C" ^ (string_of_int id)
    | Label.Fault id -> "F" ^ (string_of_int id)
    | Label.DefaultArg id -> "DV" ^ (string_of_int id)
    | Label.Named id -> id

let string_of_switch_kind kind =
  match kind with
  | Unbounded -> "Unbounded"
  | Bounded -> "Bounded"

let string_of_switch kind base labels =
  let kind = string_of_switch_kind kind in
  let labels = String.concat " " @@ List.map string_of_label labels in
  Printf.sprintf "Switch %s %d <%s>" kind base labels

let string_of_control_flow instruction =
  match instruction with
  | Jmp l -> "Jmp " ^ string_of_label l
  | JmpNS l -> "JmpNS " ^ string_of_label l
  | JmpZ l -> "JmpZ " ^ string_of_label l
  | JmpNZ l -> "JmpNZ " ^ string_of_label l
  | RetC -> "RetC"
  | RetM p -> "RetM " ^ string_of_int p
  | RetV -> "RetV"
  | Throw -> "Throw"
  | Unwind -> "Unwind"
  | Switch (kind, base, labels) -> string_of_switch kind base labels
  | _ -> failwith "instruction_control_flow Not Implemented"

let string_of_iterator_id i = Iterator.to_string i
let string_of_null_flavor nf =
  match nf with
  | Ast.OG_nullthrows -> "NullThrows"
  | Ast.OG_nullsafe -> "NullSafe"

let string_of_class_kind ck =
  match ck with
  | KClass -> "Class"
  | KInterface -> "Interface"
  | KTrait -> "Trait"

let string_of_isset instruction =
  match instruction with
  | IssetC -> "IssetC"
  | IssetL id -> "IssetL " ^ string_of_local_id id
  | IssetN -> "IssetN"
  | IssetG -> "IssetG"
  | IssetS cls -> "IssetS " ^ string_of_int cls
  | EmptyL id -> "EmptyL " ^ string_of_local_id id
  | EmptyN -> "EmptyN"
  | EmptyG -> "EmptyG"
  | EmptyS cls -> "EmptyS " ^ string_of_int cls
  | IsTypeC op -> "IsTypeC " ^ string_of_istype_op op
  | IsTypeL (id, op) ->
    "IsTypeL " ^ string_of_local_id id ^ " " ^ string_of_istype_op op

let string_of_base x =
  match x with
  | BaseNC (si, m) ->
    sep ["BaseNC"; string_of_stack_index si; MemberOpMode.to_string m]
  | BaseNL (id, m) ->
    sep ["BaseNL"; string_of_local_id id; MemberOpMode.to_string m]
  | FPassBaseNC (i, si) ->
    sep ["FBaseBaseNC"; string_of_param_num i; string_of_stack_index si]
  | FPassBaseNL (i, lid) ->
    sep ["FPassBaseNL"; string_of_param_num i; string_of_local_id lid]
  | BaseGC (si, m) ->
    sep ["BaseGC"; string_of_stack_index si; MemberOpMode.to_string m]
  | BaseGL (id, m) ->
    sep ["BaseGL"; string_of_local_id id; MemberOpMode.to_string m]
  | FPassBaseGC (i, si) ->
    sep ["FPassBaseGC"; string_of_param_num i; string_of_stack_index si]
  | FPassBaseGL (i, lid) ->
    sep ["FPassBaseGL"; string_of_param_num i; string_of_local_id lid]
  | BaseSC (si, id) ->
    sep ["BaseSC"; string_of_stack_index si; string_of_classref id]
  | BaseSL (lid, si) ->
    sep ["BaseSL"; string_of_local_id lid; string_of_stack_index si]
  | BaseL (lid, m) ->
    sep ["BaseL"; string_of_local_id lid; MemberOpMode.to_string m]
  | FPassBaseL (i, lid) ->
    sep ["FPassBaseL"; string_of_param_num i; string_of_local_id lid]
  | BaseC si ->
    sep ["BaseC"; string_of_stack_index si]
  | BaseR si ->
    sep ["BaseR"; string_of_stack_index si]
  | BaseH ->
    "BaseH"
  | Dim (m, mk) ->
    sep ["Dim"; MemberOpMode.to_string m; string_of_member_key mk]
  | FPassDim (i, mk) ->
    sep ["FPassDim"; string_of_param_num i; string_of_member_key mk]

let string_of_final instruction =
  match instruction with
  | QueryM (n, op, mk) ->
    sep ["QueryM";
      string_of_int n; QueryOp.to_string op; string_of_member_key mk]
  | VGetM (n, mk) ->
    sep ["VGetM";
      string_of_int n; string_of_member_key mk]
  | UnsetM (n, mk) ->
    sep ["UnsetM";
      string_of_int n; string_of_member_key mk]
  | BindM (n, mk) ->
    sep ["BindM";
      string_of_int n; string_of_member_key mk]
  | FPassM (i, n, mk, h) ->
    sep ["FPassM";
      string_of_param_num i; string_of_int n; string_of_member_key mk;
      string_of_fpasshint h]
  | SetM (i, mk) ->
    sep ["SetM";
      string_of_param_num i; string_of_member_key mk]
  | SetOpM (i, op, mk) ->
    sep ["SetOpM";
      string_of_param_num i; string_of_eq_op op; string_of_member_key mk]
  | IncDecM (i, op, mk) ->
    sep ["IncDecM";
      string_of_param_num i; string_of_incdec_op op; string_of_member_key mk]
  | _ ->
    "# string_of_final " ^ nyi
(*
| IncDecM of num_params * incdec_op * MemberKey.t
| SetOpM of num_params  * eq_op * MemberKey.t
| SetWithRefLML of local_id * local_id
| SetWithRefRML of local_id
*)

let string_of_param_locations pl =
  if List.length pl = 0 then "" else
  "<" ^ (String.concat ", " (List.map string_of_int pl)) ^ ">"

let string_of_call instruction =
  match instruction with
  | FPushFunc (n, pl) ->
    sep ["FPushFunc"; string_of_int n; string_of_param_locations pl]
  | FPushFuncD (n, id) ->
    sep ["FPushFuncD"; string_of_int n; string_of_function_id id]
  | FPushFuncU (n, id1, id2) ->
    sep ["FPushFuncU"; string_of_int n; string_of_function_id id1; SU.quote_string id2]
  | FPushObjMethod (n, nf, pl) ->
    sep ["FPushObjMethod"; string_of_int n; string_of_null_flavor nf; string_of_param_locations pl]
  | FPushObjMethodD (n, id, nf) ->
    sep ["FPushObjMethodD";
      string_of_int n; string_of_method_id id; string_of_null_flavor nf]
  | FPushClsMethod (n, id, pl) ->
    sep ["FPushClsMethod"; string_of_int n; string_of_classref id; string_of_param_locations pl]
  | FPushClsMethodD (n, id, cid) ->
    sep ["FPushClsMethodD";
      string_of_int n;
      string_of_method_id id; string_of_class_id cid]
  | FPushClsMethodS (n, r) ->
     sep ["FPushClsMethodS";
          string_of_int n;
          SpecialClsRef.to_string r]
  | FPushClsMethodSD (n, r, id) ->
     sep ["FPushClsMethodSD";
          string_of_int n;
          SpecialClsRef.to_string r;
          string_of_method_id id]
  | FPushCtor (n, id) ->
    sep ["FPushCtor"; string_of_int n; string_of_int id]
  | FPushCtorD (n, cid) ->
    sep ["FPushCtorD"; string_of_int n; string_of_class_id cid]
  | FPushCtorI (n, id) ->
    sep ["FPushCtorI"; string_of_int n; string_of_classref id]
  | FPushCtorS (n, r) ->
    sep ["FPushCtorS"; string_of_int n; SpecialClsRef.to_string r]
  | DecodeCufIter (id, l) ->
    sep ["DecodeCufIter"; string_of_iterator_id id; string_of_label l]
  | FPushCufIter (n, id) ->
    sep ["FPushCufIter"; string_of_int n; string_of_iterator_id id]
  | FPushCuf n ->
    sep ["FPushCuf"; string_of_int n]
  | FPushCufF n ->
    sep ["FPushCufF"; string_of_int n]
  | FPushCufSafe n ->
    sep ["FPushCufSafe"; string_of_int n]
  | CufSafeArray -> "CufSafeArray"
  | CufSafeReturn -> "CufSafeReturn"
  | FPassC (i, h) ->
    sep ["FPassC"; string_of_param_num i; string_of_fpasshint h]
  | FPassCW (i, h) ->
    sep ["FPassCW"; string_of_param_num i; string_of_fpasshint h]
  | FPassCE (i, h) ->
    sep ["FPassCE"; string_of_param_num i; string_of_fpasshint h]
  | FPassV (i, h) ->
    sep ["FPassV"; string_of_param_num i; string_of_fpasshint h]
  | FPassVNop (i, h) ->
    sep ["FPassVNop"; string_of_param_num i; string_of_fpasshint h]
  | FPassR (i, h) ->
    sep ["FPassR"; string_of_param_num i; string_of_fpasshint h]
  | FPassL (i, lid, h) ->
    sep ["FPassL"; string_of_param_num i; string_of_local_id lid;
         string_of_fpasshint h]
  | FPassN (i, h) ->
    sep ["FPassN"; string_of_param_num i; string_of_fpasshint h]
  | FPassG (i, h) ->
    sep ["FPassG"; string_of_param_num i; string_of_fpasshint h]
  | FPassS (i, id, h) ->
    sep ["FPassS"; string_of_param_num i; string_of_classref id;
         string_of_fpasshint h]
  | FCall n ->
    sep ["FCall"; string_of_int n]
  | FCallD (n, c, f) ->
    sep ["FCallD";
      string_of_int n; string_of_class_id c; string_of_function_id f]
  | FCallArray -> "FCallArray"
  | FCallAwait (n, c, f) ->
    sep ["FCallAwait";
      string_of_int n; string_of_class_id c; string_of_function_id f]
  | FCallUnpack n ->
    sep ["FCallUnpack"; string_of_int n]
  | FCallBuiltin (n1, n2, id) ->
    sep ["FCallBuiltin"; string_of_int n1; string_of_int n2; SU.quote_string id]
  | RaiseFPassWarning (h, f, n) ->
    sep ["RaiseFPassWarning"; string_of_fpasshint h; "\"" ^ f ^ "\""; string_of_param_id n]
  | FCallM (n1, n2) ->
    sep ["FCallM"; string_of_int n1; string_of_int n2]
  | FCallUnpackM (n1, n2) ->
    sep ["FCallUnpackM"; string_of_int n1; string_of_int n2]
  | FCallDM (n1, n2, c, f) ->
    sep ["FCallDM";
      string_of_int n1; string_of_int n2; string_of_class_id c;
      string_of_function_id f]

let string_of_barethis_op i =
  match i with
  | Notice -> "Notice"
  | NoNotice -> "NoNotice"
  | NeverNull -> "NeverNull"

let string_of_op_silence op =
  match op with
  | Start -> "Start"
  | End -> "End"

let string_of_misc instruction =
  match instruction with
    | This -> "This"
    | BareThis op -> sep ["BareThis"; string_of_barethis_op op]
    | Self id -> sep ["Self"; string_of_classref id]
    | Parent id -> sep ["Parent"; string_of_classref id]
    | LateBoundCls id -> sep ["LateBoundCls"; string_of_classref id]
    | ClsRefName id -> sep ["ClsRefName"; string_of_classref id]
    | VerifyParamType id -> sep ["VerifyParamType"; string_of_param_id id]
    | VerifyOutType id -> sep ["VerifyOutType"; string_of_param_id id]
    | VerifyRetTypeC -> "VerifyRetTypeC"
    | VerifyRetTypeV -> "VerifyRetTypeV"
    | Catch -> "Catch"
    | CheckThis -> "CheckThis"
    | IsUninit -> "IsUninit"
    | CGetCUNop -> "CGetCUNop"
    | UGetCUNop -> "UGetCUNop"
    | StaticLocCheck (local, text) ->
      sep ["StaticLocCheck"; string_of_local_id local; "\"" ^ text ^ "\""]
    | StaticLocDef (local, text) ->
      sep ["StaticLocDef"; string_of_local_id local; "\"" ^ text ^ "\""]
    | StaticLocInit (local, text) ->
      sep ["StaticLocInit"; string_of_local_id local; "\"" ^ text ^ "\""]
    | MemoGet (count, Local.Unnamed first, local_count) ->
      Printf.sprintf "MemoGet %s L:%d+%d"
        (string_of_int count) first (local_count - 1)
    | MemoGet _ -> failwith "MemoGet needs an unnamed local"
    | MemoSet (count, Local.Unnamed first, local_count) ->
      Printf.sprintf "MemoSet %s L:%d+%d"
        (string_of_int count) first (local_count - 1)
    | MemoSet _ -> failwith "MemoSet needs an unnamed local"
    | GetMemoKeyL local ->
      sep ["GetMemoKeyL"; string_of_local_id local]
    | IsMemoType -> "IsMemoType"
    | MaybeMemoType -> "MaybeMemoType"
    | CreateCl (n, cid) ->
      sep ["CreateCl"; string_of_int n; string_of_int cid]
    | Idx -> "Idx"
    | ArrayIdx -> "ArrayIdx"
    | InitThisLoc id -> sep ["InitThisLoc"; string_of_local_id id]
    | AKExists -> "AKExists"
    | OODeclExists ck -> sep ["OODeclExists"; string_of_class_kind ck]
    | Silence (local, op) ->
      sep ["Silence"; string_of_local_id local; string_of_op_silence op]
    | AssertRATL (local, s) ->
      sep ["AssertRATL"; string_of_local_id local; s]
    | AssertRATStk (n, s) ->
      sep ["AssertRATStk"; string_of_int n; s]
    | NativeImpl -> "NativeImpl"
    | _ -> failwith "instruct_misc Not Implemented"

let iterator_instruction_name_prefix instruction =
  let iterator_instruction_name =
    match instruction with
    | IterInit _ -> "IterInit"
    | MIterInit _ -> "MIterInit"
    | IterInitK _ -> "IterInitK"
    | MIterInitK _ -> "MIterInitK"
    | IterNext _ -> "IterNext"
    | MIterNext _ -> "MIterNext"
    | IterNextK _ -> "IterNextK"
    | MIterNextK _ -> "MIterNextK"
    | IterFree _ -> "IterFree"
    | MIterFree _ -> "MIterFree"
    | CIterFree _ -> "CIterFree"
    | _ -> failwith "invalid iterator instruction"
  in
  iterator_instruction_name ^ " "

let string_of_iterator instruction =
  match instruction with
  | IterInit (id, label, value)
  | MIterInit (id, label, value) ->
    (iterator_instruction_name_prefix instruction) ^
    (string_of_iterator_id id) ^ " " ^
    (string_of_label label) ^ " " ^
    (string_of_local_id value)
  | IterInitK (id, label, key, value)
  | MIterInitK (id, label, key, value) ->
    (iterator_instruction_name_prefix instruction) ^
    (string_of_iterator_id id) ^ " " ^
    (string_of_label label) ^ " " ^
    (string_of_local_id key) ^ " " ^
    (string_of_local_id value)
  | IterNext (id, label, value)
  | MIterNext (id, label, value) ->
    (iterator_instruction_name_prefix instruction) ^
    (string_of_iterator_id id) ^ " " ^
    (string_of_label label) ^ " " ^
    (string_of_local_id value)
  | IterNextK (id, label, key, value)
  | MIterNextK (id, label, key, value) ->
    (iterator_instruction_name_prefix instruction) ^
    (string_of_iterator_id id) ^ " " ^
    (string_of_label label) ^ " " ^
    (string_of_local_id key) ^ " " ^
    (string_of_local_id value)
  | IterFree id
  | MIterFree id
  | CIterFree id ->
    (iterator_instruction_name_prefix instruction) ^
    (string_of_iterator_id id)
  | IterBreak (label, iterlist) ->
      let map_item (is_mutable, id) =
        (if is_mutable then "(MIter) " else "(Iter) ") ^
        (string_of_iterator_id id)
      in
      let values =
        String.concat ", " (List.rev_map map_item iterlist) in
      "IterBreak " ^ (string_of_label label) ^ " <" ^ values ^ ">"
  | _ -> "### string_of_iterator instruction not implemented"

let string_of_try instruction =
  match instruction with
  | TryFaultBegin label ->
    ".try_fault " ^ (string_of_label label) ^ " {"
  | TryCatchLegacyBegin label ->
    ".try_catch " ^ (string_of_label label) ^ " {"
  | TryFaultEnd
  | TryCatchLegacyEnd -> "}"
  | TryCatchBegin -> ".try {"
  | TryCatchMiddle -> "} .catch {"
  | TryCatchEnd -> "}"

let string_of_async = function
  | Await -> "Await"
  | WHResult -> "WHResult"
  | AwaitAll (Local.Unnamed local, count) ->
    Printf.sprintf "AwaitAll L:%d+%d" local count
  | AwaitAll _ -> failwith "AwaitAll needs an unnamed local"

let string_of_generator = function
  | CreateCont -> "CreateCont"
  | Yield -> "Yield"
  | YieldK -> "YieldK"
  | _ -> "### string_of_generator - " ^ nyi

let string_of_include_eval_define = function
  | Incl -> "Incl"
  | InclOnce -> "InclOnce"
  | Req -> "Req"
  | ReqOnce -> "ReqOnce"
  | ReqDoc -> "ReqDoc"
  | Eval -> "Eval"
  | AliasCls (c1, c2) ->
    sep ["AliasCls"; SU.quote_string c1; SU.quote_string c2]
  | DefFunc id -> sep ["DefFunc"; string_of_function_num id]
  | DefCls id -> sep ["DefCls"; string_of_class_num id]
  | DefClsNop id -> sep ["DefClsNop"; string_of_class_num id]
  | DefCns id -> sep ["DefCns"; string_of_const_id id]
  | DefTypeAlias id -> sep ["DefTypeAlias"; string_of_typedef_num id]

let string_of_free_iterator = function
  | IgnoreIter -> "IgnoreIter"
  | FreeIter -> "FreeIter"

let string_of_gen_delegation = function
  | ContAssignDelegate i -> sep ["ContAssignDelegate"; string_of_iterator_id i]
  | ContEnterDelegate -> "ContEnterDelegate"
  | YieldFromDelegate (i, l) ->
    sep ["YieldFromDelegate"; string_of_iterator_id i; string_of_label l]
  | ContUnsetDelegate (free, i) ->
    sep ["ContUnsetDelegate";
         string_of_free_iterator free;
         string_of_iterator_id i]

let string_of_instruction instruction =
  let s = match instruction with
  | IIterator            i -> string_of_iterator i
  | IBasic               i -> string_of_basic i
  | ILitConst            i -> string_of_lit_const i
  | IOp                  i -> string_of_operator i
  | IContFlow            i -> string_of_control_flow i
  | ICall                i -> string_of_call i
  | IMisc                i -> string_of_misc i
  | IGet                 i -> string_of_get i
  | IMutator             i -> string_of_mutator i
  | ILabel               l -> string_of_label l ^ ":"
  | IIsset               i -> string_of_isset i
  | IBase                i -> string_of_base i
  | IFinal               i -> string_of_final i
  | ITry                 i -> string_of_try i
  | IComment             s -> "# " ^ s
  | ISrcLoc              p -> ".srcloc " ^ string_of_pos p ^ ";"
  | IAsync               i -> string_of_async i
  | IGenerator           i -> string_of_generator i
  | IIncludeEvalDefine   i -> string_of_include_eval_define i
  | IGenDelegation       i -> string_of_gen_delegation i
  | _ -> failwith "invalid instruction" in
  s ^ "\n"

let adjusted_indent instruction indent =
  match instruction with
  | IComment _ -> 0
  | ILabel _
  | ITry TryFaultEnd
  | ITry TryCatchLegacyEnd
  | ITry TryCatchMiddle
  | ITry TryCatchEnd -> indent - 2
  | _ -> indent

let new_indent instruction indent =
  match instruction with
  | ITry (TryFaultBegin _)
  | ITry (TryCatchLegacyBegin _)
  | ITry TryCatchBegin -> indent + 2
  | ITry TryFaultEnd
  | ITry TryCatchLegacyEnd
  | ITry TryCatchEnd -> indent - 2
  | _ -> indent

let add_instruction_list buffer indent instructions =
  let rec aux instructions indent =
    match instructions with
    | [] -> ()
    | ISpecialFlow _ :: t ->
      let fatal =
        Emit_fatal.emit_fatal_runtime Pos.none "Cannot break/continue 1 level"
      in
      let fatal = Instruction_sequence.instr_seq_to_list fatal in
      aux fatal indent;
      aux t indent
    | instruction :: t ->
      begin
      let actual_indent = adjusted_indent instruction indent in
      B.add_string buffer (String.make actual_indent ' ');
      B.add_string buffer (string_of_instruction instruction);
      aux t (new_indent instruction indent)
      end in
  aux instructions indent

(* HHVM uses `N` to denote absence of type information. Otherwise the type
 * is a quoted string *)
let quote_str_option s =
  match s with
  | None -> "N"
  | Some s -> SU.quote_string s

let string_of_type_flags flags =
  let flag_strs = List.map Hhas_type_constraint.string_of_flag flags in
  let flags_text = String.concat " " flag_strs in
  flags_text

let string_of_type_info ?(is_enum = false) ti =
  let user_type = Hhas_type_info.user_type ti in
  let type_constraint = Hhas_type_info.type_constraint ti in
  let flags = Hhas_type_constraint.flags type_constraint in
  let flags_text = string_of_type_flags flags in
  let name = Hhas_type_constraint.name type_constraint in
    "<" ^ quote_str_option user_type ^ " "
        ^ (if not is_enum then quote_str_option name ^ " " else "")
        ^ flags_text
    ^ " >"

let string_of_typedef_info ti =
  let type_constraint = Hhas_type_info.type_constraint ti in
  let name = Hhas_type_constraint.name type_constraint in
  let flags = Hhas_type_constraint.flags type_constraint in
  (* TODO: check if other flags are emitted for type aliases *)
  let flags = List.filter (fun f -> f = Hhas_type_constraint.Nullable) flags in
  let flags_text = string_of_type_flags flags in
    "<" ^ SU.quote_string (Option.value ~default:"" name)
    ^ " " ^ flags_text ^ " >"

let string_of_type_info_option tio =
  match tio with
  | None -> ""
  | Some ti -> string_of_type_info ti ^ " "

type default_value_printing_env = {
  codegen_env      : Emit_env.t option;
  use_single_quote : bool;
}

let rec string_of_afield ~env = function
  | A.AFvalue e ->
    string_of_param_default_value ~env e
  | A.AFkvalue (k, v) ->
    string_of_param_default_value ~env k ^
    " => " ^ string_of_param_default_value ~env v

and string_of_afield_list ~env afl =
  if List.length afl = 0
  then ""
  else String.concat ", " @@ List.map (string_of_afield ~env) afl

and shape_field_name_to_expr = function
  | A.SFlit (pos, s)
  | A.SFclass_const (_, (pos, s)) -> (pos, A.String (pos, s))

and string_of_bop = function
  | A.Plus -> "+"
  | A.Minus -> "-"
  | A.Star -> "*"
  | A.Slash -> "/"
  | A.Eqeq -> "=="
  | A.EQeqeq -> "==="
  | A.Starstar -> "**"
  | A.Eq None -> "="
  | A.Eq (Some bop) -> "=" ^ string_of_bop bop
  | A.AMpamp -> "&&"
  | A.BArbar -> "||"
  | A.Lt -> "<"
  | A.Lte -> "<="
  | A.Cmp -> "<=>"
  | A.Gt -> ">"
  | A.Gte -> ">="
  | A.Dot -> "."
  | A.Amp -> "&"
  | A.Bar -> "|"
  | A.Ltlt -> "<<"
  | A.Gtgt -> ">>"
  | A.Percent -> "%"
  | A.Xor -> "^"
  | A.LogXor -> "xor"
  | A.Diff -> "!="
  | A.Diff2 -> "!=="

and string_of_uop = function
  | A.Utild -> "~"
  | A.Unot -> "!"
  | A.Uplus -> "+"
  | A.Uminus -> "-"
  | A.Uincr -> "++"
  | A.Udecr -> "--"
  | A.Uref -> "&"
  | A.Usilence -> "@"
  | A.Upincr
  | A.Updecr
    -> failwith "string_of_uop - should have been captures earlier"

and string_of_hint ~ns h =
  let h =
    Emit_type_hint.fmt_hint
      ~tparams:[]
      ~namespace:Namespace_env.empty_with_default_popt
      h
  in
  let h = if ns then h else SU.strip_ns h in
  Php_escaping.escape h

and string_of_import_flavor = function
  | A.Include -> "include"
  | A.Require -> "require"
  | A.IncludeOnce -> "include_once"
  | A.RequireOnce -> "require_once"

and string_of_is_variadic b =
  if b then "..." else ""
and string_of_is_reference b =
  if b then "&" else ""

and string_of_fun ~env f use_list =
  let string_of_args p =
    match snd @@ p.A.param_id with
    | "" | "..." -> None
    | name ->
    let inout = if p.A.param_callconv = Some A.Pinout then "inout " else "" in
    let hint =
      Option.value_map p.A.param_hint ~default:"" ~f:(string_of_hint ~ns:true)
    in
    let default_val =
      Option.value_map
        p.A.param_expr
        ~default:""
        ~f:(fun e -> " = " ^ (string_of_param_default_value ~env e)) in
    let param_text =
      inout ^ string_of_is_variadic p.A.param_is_variadic ^ hint in
    let param_text =
      if String.length param_text = 0
      then param_text
      else param_text ^ " " in
    let param_text =
      param_text ^ string_of_is_reference p.A.param_is_reference ^ name in
    Some (param_text ^ default_val)
  in
  let args = String.concat ", " @@ Core_list.filter_map ~f:string_of_args f.A.f_params in
  let use_list_helper ((_, id), b) = (if b then "&" else "") ^ id in
  let use_statement = match use_list with
    | [] -> ""
    | _ ->
      "use ("
      ^ (String.concat ", " @@ List.map use_list_helper use_list)
      ^ ") "
  in
  (if f.A.f_static then "static " else "")
  ^ "function ("
  ^ args
  ^ ") "
  ^ use_statement
  ^ (string_of_statement ~env ~indent:"" (Pos.none, A.Block f.A.f_body))

and string_of_optional_expr ~env e =
  string_of_optional_value (string_of_expression ~env) e

and string_of_block_ ~env ~start_indent ~block_indent ~end_indent block =
  let lines =
    (String.concat "" @@
      List.map (string_of_statement ~env ~indent:block_indent) block) in
  start_indent ^ "{\\n" ^ lines ^ end_indent ^ "}\\n"

and string_of_block ~env ~indent (block:A.stmt list) =
  match block with
  | [] | [_, A.Noop] -> ""
  | [(_, A.Block ([_] as block))]
  | (_::_::_ as block)->
    string_of_block_
      ~env
      ~start_indent:""
      ~block_indent:(indent ^ indent_text)
      ~end_indent:indent
      block
  | [stmt] ->
    string_of_statement ~env ~indent:"" stmt

and string_of_statement ~env ~indent ((_, stmt_) : A.stmt) =
  let text, is_single_line =
    match stmt_ with
    | A.Return e ->
      "return" ^ (string_of_optional_expr ~env e), true
    | A.Expr e ->
      string_of_expression ~env e, true
    | A.Break level_opt ->
      "break" ^ (string_of_optional_expr ~env level_opt), true
    | A.Continue level_opt ->
      "continue" ^ (string_of_optional_expr ~env level_opt), true
    | A.Throw e ->
      "throw " ^ (string_of_expression ~env e), true
    | A.Block block ->
      string_of_block_
        ~env
        ~start_indent:indent
        ~block_indent:(indent ^ indent_text)
        ~end_indent:indent
        block,
      false
    | A.While (cond, body) ->
      let header_text =
        indent ^ "while (" ^ (string_of_expression ~env cond) ^ ") " in
      let body_text =
        string_of_block
        ~env
        ~indent
        body in
      header_text ^ body_text, false

    | A.If (cond, then_block, else_block) ->
      let header_text =
        indent ^ "if (" ^ (string_of_expression ~env cond) ^ ") " in
      let then_text = string_of_block
        ~env
        ~indent
        then_block in
      let else_text = string_of_block
        ~env
        ~indent
        else_block in
      header_text ^ then_text ^
      (if String.length else_text <> 0 then " else " ^ else_text else ""),
      false
    | A.Noop -> "", false
    | _ -> nyi, false in
  let text =
    if is_single_line then indent ^ text ^ ";\\n"
    else text in
  text

and string_of_expression ~env e =
  string_of_param_default_value ~env:{ env with use_single_quote = true } e

and string_of_xml ~env (_, id) attributes children =
  let p = Pos.none in
  let name = SU.Xhp.mangle id in
  let _, attributes =
    List.fold_right (string_of_xhp_attr p) attributes (0, [])
  in
  let attributes = string_of_param_default_value ~env (p, A.Array attributes) in
  let children = string_of_param_default_value ~env
   (p, A.Array (List.map (fun e -> A.AFvalue e) children))
  in
  "new "
  ^ name
  ^ "("
  ^ attributes
  ^ ", "
  ^ children
  ^ ", __FILE__, __LINE__)"

and string_of_xhp_attr p attr (spread_id, attrs) = match attr with
  | A.Xhp_simple (id, e) -> (spread_id, (A.AFkvalue ((p, A.String id), e))::attrs)
  | A.Xhp_spread e ->
    let id = (p, "...$" ^ (string_of_int spread_id)) in
    (spread_id + 1, (A.AFkvalue ((p, A.String id), e))::attrs)

and string_of_param_default_value ~env expr =
  let p = Pos.none in
  let middle_aux e1 s e2 =
    let e1 = string_of_param_default_value ~env e1 in
    let e2 = string_of_param_default_value ~env e2 in
    e1 ^ s ^ e2
  in
  let fmt_class_name ~is_class_constant cn =
    let cn = (Php_escaping.escape (SU.strip_global_ns cn)) in
    if is_class_constant then "\\\\" ^ cn else cn in
  let get_special_class_name ~env ~is_class_constant id =
    let scope = match env with
      | None -> Ast_scope.Scope.toplevel
      | Some env -> Emit_env.get_scope env in
    let module ACE = Ast_class_expr in
    let e =
      let p0 = Pos.none in
      (p0, (A.Id (p0, id))) in
    fmt_class_name ~is_class_constant @@
      match ACE.expr_to_class_expr ~check_traits:true ~resolve_self:true scope e with
      | ACE.Class_id (_, name) -> name
      | _ -> id
  in
  let get_class_name_from_id ~env ~should_format ~is_class_constant id =
    if id = SN.Classes.cSelf || id = SN.Classes.cParent || id = SN.Classes.cStatic
    then get_special_class_name ~env ~is_class_constant id
    else
    let id =
      match env with
      | Some env ->
        Hhbc_id.Class.to_raw_string @@ fst @@
          Hhbc_id.Class.elaborate_id
            (Emit_env.get_namespace env) (p, id)
      | _ -> id
    in
    if should_format then fmt_class_name ~is_class_constant id else id
  in
  let handle_possible_colon_colon_class_expr ~env ~is_array_get = function
    | _, A.Class_const ((_, A.Id (p, s1)), (_, s2))
      when SU.is_class s2 && not
        (SU.is_self s1 || SU.is_parent s1 || SU.is_static s1) ->

      let s1 = get_class_name_from_id
        ~env:env.codegen_env ~should_format:false ~is_class_constant:false s1 in
      let e =
        (fst expr, if is_array_get then A.Id (p, s1) else A.String (p, s1)) in
      let env = { env with use_single_quote = false } in
      Some (string_of_param_default_value ~env e)
    | _ -> None
  in
  let escape_char_for_printing = function
    | '\\' | '$' | '"' -> "\\\\"
    | '\n' | '\r' | '\t' -> "\\"
    | c when not (Php_escaping.is_lit_printable c) -> "\\"
    | _ -> ""
  in
  let escape_fn c = escape_char_for_printing c ^ Php_escaping.escape_char c in
  match snd expr with
  | A.Id (p, id) ->
    let id = match env.codegen_env with
      | Some env when SU.has_ns id ->
        let id, _, _ =
          Hhbc_id.Const.elaborate_id
            (Emit_env.get_namespace env) (p, id)
        in
        "\\" ^ Hhbc_id.Const.to_raw_string id
      | _ -> id
    in
    Php_escaping.escape id
  | A.Id_type_arguments ((_, litstr), _)
  | A.Lvar (_, litstr) -> Php_escaping.escape litstr
  | A.Float (_, litstr) -> SU.Float.with_scientific_notation litstr
  | A.Int (_, litstr) -> SU.Integer.to_decimal litstr
  | A.String (_, litstr) ->
    if env.use_single_quote
    then SU.single_quote_string_with_escape ~f:escape_fn litstr
    else SU.quote_string_with_escape ~f:escape_fn litstr
  | A.Null -> "NULL"
  | A.True -> "true"
  | A.False -> "false"
  (* For arrays and collections, we are making a conscious decision to not
   * match HHMV has HHVM's emitter has inconsistencies in the pretty printer
   * https://fburl.com/tzom2qoe *)
  | A.Array afl ->
    "array(" ^ string_of_afield_list ~env afl ^ ")"
  | A.Collection ((_, name), afl) when
    name = "vec" || name = "dict" || name = "keyset" ->
    let env = { env with use_single_quote = false } in
    name ^ "[" ^ string_of_afield_list ~env afl ^ "]"
  | A.Collection ((_, name), afl) ->
    let name = SU.Types.fix_casing @@ SU.strip_ns name in
    begin match name with
    | "Set" | "Pair" | "Vector" | "Map"
    | "ImmSet" | "ImmVector" | "ImmMap" ->
      let elems = string_of_afield_list ~env afl in
      let elems =
        if String.length elems <> 0 then " " ^ elems ^ " " else elems in
      "HH\\\\" ^ name ^ " {" ^ elems ^ "}"
    | _ ->
      nyi ^ " - Default value for an unknown collection - " ^ name
    end
  | A.Shape fl ->
    let fl =
      List.map
        (fun (f_name, e) ->
          A.AFkvalue (shape_field_name_to_expr f_name, e))
        fl
    in
    string_of_param_default_value ~env (fst expr, A.Array fl)
  | A.Binop (bop, e1, e2) ->
    let bop = string_of_bop bop in
    let e1 = string_of_param_default_value ~env e1 in
    let e2 = string_of_param_default_value ~env e2 in
    e1 ^ " " ^ bop ^ " " ^ e2
  | A.New (e, es, ues)
  | A.Call (e, _, es, ues) ->
    let e = String_utils.lstrip (string_of_param_default_value ~env e) "\\\\" in
    let es = List.map (string_of_param_default_value ~env) (es @ ues) in
    let prefix = match snd expr with A.New (_, _, _) -> "new " | _ -> "" in
    prefix
    ^ e
    ^ "("
    ^ String.concat ", " es
    ^ ")"
  | A.NewAnonClass (es, ues, _) ->
    let es = List.map (string_of_param_default_value ~env) (es @ ues) in
    "new class"
    ^ "("
    ^ String.concat ", " es
    ^ ")"
  | A.Class_get (e1, e2) ->
    let s1 = match snd e1 with
      | A.Id (_, s1) ->
        get_class_name_from_id
          ~env:env.codegen_env ~should_format:true ~is_class_constant:false s1
      | _ -> string_of_param_default_value ~env e1 in
    let s2 = match snd e2 with
      | A.Dollar e -> "$" ^ string_of_param_default_value ~env e
      | _ -> string_of_param_default_value ~env e2 in
    s1 ^ "::" ^ s2
  | A.Class_const (e1, (_, s2)) ->
    let cexpr_o =
      handle_possible_colon_colon_class_expr ~env ~is_array_get:false expr in
    begin match snd e1, cexpr_o with
    | _, Some cexpr_o -> cexpr_o
    | A.Id (_, s1), _ ->
      let s1 = get_class_name_from_id
        ~env:env.codegen_env ~should_format:true ~is_class_constant:true s1 in
      s1 ^ "::" ^ s2
    | _ ->
      let s1 = string_of_param_default_value ~env e1 in
      s1 ^ "::" ^ s2
    end
  | A.Unop (uop, e) -> begin
    let e = string_of_param_default_value ~env e in
    match uop with
    | A.Upincr -> e ^ "++"
    | A.Updecr -> e ^ "--"
    | _ -> string_of_uop uop ^ e
    end
  | A.Obj_get (e1, e2, f) ->
    let e1 = string_of_param_default_value ~env e1 in
    let e2 = string_of_param_default_value ~env e2 in
    let f = match f with A.OG_nullthrows -> "->" | A.OG_nullsafe -> "\\?->" in
    e1 ^ f ^ e2
  | A.Clone e -> "clone " ^ string_of_param_default_value ~env e
  | A.Array_get (e, eo) ->
    let e = string_of_param_default_value ~env e in
    let eo =
      Option.value_map eo ~default:""
        ~f:(fun e ->
              let cexpr_o =
                handle_possible_colon_colon_class_expr
                  ~env ~is_array_get:true e in
              match cexpr_o with
              | Some s -> s
              | None -> string_of_param_default_value ~env e)
    in
    e ^ "[" ^ eo ^ "]"
  | A.String2 es ->
    String.concat " . " @@ List.map (string_of_param_default_value ~env) es
  | A.Execution_operator es ->
    let s =
      String.concat " . " @@ List.map (string_of_param_default_value ~env) es in
    "shell_exec(" ^ s ^ ")"
  | A.Eif (cond, etrue, efalse) ->
    let cond = string_of_param_default_value ~env cond in
    let etrue =
      Option.value_map etrue ~default:"" ~f:(string_of_param_default_value ~env)
    in
    let efalse = string_of_param_default_value ~env efalse in
    cond ^ " \\? " ^ etrue ^ " : " ^ efalse
  | A.Unsafeexpr e -> string_of_param_default_value ~env  e
  | A.BracedExpr e -> "{" ^ string_of_param_default_value ~env e ^ "}"
  | A.Dollar e ->
    "${" ^ string_of_param_default_value ~env e ^ "}"
  | A.ParenthesizedExpr e -> "(" ^ string_of_param_default_value ~env e ^ ")"
  | A.Cast (h, e) ->
    let h = string_of_hint ~ns: false h in
    let e = string_of_param_default_value ~env e in
    "(" ^ h ^ ")" ^ e
  | A.Pipe (e1, e2) -> middle_aux e1 " |> " e2
  | A.NullCoalesce (e1, e2) -> middle_aux e1 " \\?\\? " e2
  | A.InstanceOf (e1, e2) -> middle_aux e1 " instanceof " e2
  | A.Is (e, h) ->
    let e = string_of_param_default_value ~env e in
    let h = string_of_hint ~ns:true h in
      e ^ " is " ^ h
  | A.Varray es ->
    let index i = p, A.Int (p, string_of_int i) in
    string_of_param_default_value ~env @@
     (p, A.Array (List.mapi (fun i e -> A.AFkvalue (index i, e)) es))
  | A.Darray es ->
    string_of_param_default_value ~env @@
     (p, A.Array (List.map (fun (e1, e2) -> A.AFkvalue (e1, e2)) es))
  | A.Import (fl, e) ->
    let fl = string_of_import_flavor fl in
    let e = string_of_param_default_value ~env e in
    fl ^ " " ^ e
  | A.Xml (id, attributes, children) ->
    string_of_xml ~env id attributes children
  | A.Efun (f, use_list) -> string_of_fun ~env f use_list
  | A.Lfun _ ->
    failwith "expected Lfun to be converted to Efun during closure conversion"
  | A.Yield _
  | A.Yield_break
  | A.Yield_from _
  | A.Await _
  | A.Suspend _
  | A.List _
  | A.Omitted
  | A.Callconv _
  | A.Expr_list _ -> failwith "illegal default value"

let string_of_param_default_value_option env = function
  | None -> ""
  | Some (label, expr) ->
    let use_single_quote =
      match snd expr with A.String _ -> false | _ -> true in
    let env = { codegen_env = env; use_single_quote } in
    " = "
    ^ (string_of_label label)
    ^ "(\"\"\""
    ^ (string_of_param_default_value ~env expr)
    ^ "\"\"\")"

let string_of_param_user_attributes p =
  match Hhas_param.user_attributes p with
  | [] -> ""
  | user_attrs ->
    let attrs = Emit_adata.attributes_to_strings user_attrs in
    "[" ^ (String.concat " " attrs) ^ "]"

let string_of_is_inout b = if b then "inout " else ""

let string_of_param env p =
  let param_type_info = Hhas_param.type_info p in
  let param_name = Hhas_param.name p in
  let param_default_value = Hhas_param.default_value p in
    string_of_param_user_attributes p
  ^ string_of_is_inout (Hhas_param.is_inout p)
  ^ string_of_is_variadic (Hhas_param.is_variadic p)
  ^ string_of_type_info_option param_type_info
  ^ string_of_is_reference (Hhas_param.is_reference p)
  ^ param_name
  ^ string_of_param_default_value_option env param_default_value

let string_of_params env ps =
  "(" ^ String.concat ", " (List.map (string_of_param env) ps) ^ ")"

let add_indent buf indent = B.add_string buf (String.make indent ' ')
let add_indented_line buf indent str =
  B.add_string buf "\n";
  add_indent buf indent;
  B.add_string buf str

let add_num_cls_ref_slots buf indent num_cls_ref_slots =
  if num_cls_ref_slots <> 0
  then add_indented_line buf indent
    (Printf.sprintf ".numclsrefslots %d;" num_cls_ref_slots)

let is_bareword_char c =
  match Char.lowercase_ascii c with
  | '_' | '.' | '$' | '\\' -> true
  | c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')

let is_bareword_string s =
  let rec aux i =
    i >= String.length s || (is_bareword_char (String.get s i) && aux (i + 1)) in
  aux 0

let add_decl_vars buf indent decl_vars =
  let decl_vars = List.map (fun s ->
    if is_bareword_string s
    then s
    else "\"" ^ (Php_escaping.escape s) ^ "\""
  ) decl_vars in
  if decl_vars <> []
  then add_indented_line buf indent
    (".declvars " ^ String.concat " " decl_vars ^ ";")

let add_num_iters buf indent num_iters =
  if num_iters <> 0
  then add_indented_line buf indent
    (Printf.sprintf ".numiters %d;" num_iters)

let add_static_default_value_option buf indent label =
  add_indented_line buf indent (".static " ^ label ^ ";")

let add_static_values buf indent lst =
  Hh_core.List.iter lst
    (fun label -> add_static_default_value_option buf indent label)

let add_doc buf indent doc_comment =
  match doc_comment with
  | Some cmt ->
    add_indented_line buf indent @@
      Printf.sprintf ".doc %s;" (SU.triple_quote_string cmt)
  | None -> ()

let add_body buf indent body =
  add_doc buf indent (Hhas_body.doc_comment body);
  add_num_iters buf indent (Hhas_body.num_iters body);
  if Hhas_body.is_memoize_wrapper body
  then add_indented_line buf indent ".ismemoizewrapper;";
  add_num_cls_ref_slots buf indent (Hhas_body.num_cls_ref_slots body);
  add_decl_vars buf indent (Hhas_body.decl_vars body);
  add_static_values buf indent (Hhas_body.static_inits body);
  B.add_string buf "\n";
  add_instruction_list buf indent
    (Instruction_sequence.instr_seq_to_list (Hhas_body.instrs body))

let function_attributes f =
  let user_attrs = Hhas_function.attributes f in
  let attrs = Emit_adata.attributes_to_strings user_attrs in
  let attrs = if Emit_env.is_systemlib ()
    then "unique" :: "builtin" :: "persistent" :: attrs else attrs in
  let attrs =
    if not (Hhas_function.is_top f) then "nontop" :: attrs else attrs in
  let attrs =
    if Hhas_function.inout_wrapper f then "inout_wrapper" :: attrs else attrs in
  let attrs =
    if Hhas_function.no_injection f then "no_injection" :: attrs else attrs in
  let attrs =
    if Hhas_function.is_return_by_ref f then "reference" :: attrs else attrs in
  let attrs =
    if Hhas_function.is_interceptable f then "interceptable" :: attrs else attrs in
  let text = String.concat " " attrs in
  if text = "" then "" else "[" ^ text ^ "] "

let add_fun_def buf fun_def =
  let function_name = Hhas_function.name fun_def in
  let function_body = Hhas_function.body fun_def in
  let function_span = Hhas_function.span fun_def in
  let function_return_type = Hhas_body.return_type function_body in
  let env = Hhas_body.env function_body in
  let function_params = Hhas_body.params function_body in
  let function_is_async = Hhas_function.is_async fun_def in
  let function_is_generator = Hhas_function.is_generator fun_def in
  let function_is_pair_generator = Hhas_function.is_pair_generator fun_def in
  B.add_string buf "\n.function ";
  B.add_string buf (function_attributes fun_def);
  if Hhbc_options.source_mapping !Hhbc_options.compiler_options
  then B.add_string buf (string_of_span function_span ^ " ");
  B.add_string buf (string_of_type_info_option function_return_type);
  B.add_string buf (Hhbc_id.Function.to_raw_string function_name);
  B.add_string buf (string_of_params env function_params);
  if function_is_generator then B.add_string buf " isGenerator";
  if function_is_async then B.add_string buf " isAsync";
  if function_is_pair_generator then B.add_string buf " isPairGenerator";
  B.add_string buf " {";
  add_body buf 2 function_body;
  B.add_string buf "}\n"

let attributes_to_string attrs =
  let text = String.concat " " attrs in
  let text = if text = "" then "" else "[" ^ text ^ "] " in
  text

let method_attributes m =
  let user_attrs = Hhas_method.attributes m in
  let attrs = Emit_adata.attributes_to_strings user_attrs in
  let attrs = if Emit_env.is_systemlib ()
    then "unique" :: "builtin" :: "persistent" :: attrs else attrs in
  let attrs = if Hhas_method.inout_wrapper m then "inout_wrapper" :: attrs else attrs in
  let attrs = if Hhas_method.no_injection m then "no_injection" :: attrs else attrs in
  let attrs = if Hhas_method.is_abstract m then "abstract" :: attrs else attrs in
  let attrs = if Hhas_method.is_final m then "final" :: attrs else attrs in
  let attrs = if Hhas_method.is_static m then "static" :: attrs else attrs in
  let attrs = if Hhas_method.is_public m then "public" :: attrs else attrs in
  let attrs = if Hhas_method.is_protected m then "protected" :: attrs else attrs in
  let attrs = if Hhas_method.is_private m then "private" :: attrs else attrs in
  let attrs = if Hhas_method.is_return_by_ref m then "reference" :: attrs else attrs in
  let attrs = if Hhas_method.is_interceptable m then "interceptable" :: attrs else attrs in
  attributes_to_string attrs

let typedef_attributes t =
  let user_attrs = Hhas_typedef.attributes t in
  let attrs = Emit_adata.attributes_to_strings user_attrs in
  let attrs =
    if Emit_env.is_systemlib () then "persistent" :: attrs else attrs in
  attributes_to_string attrs

let add_method_def buf method_def =
  let method_name = Hhas_method.name method_def in
  let method_body = Hhas_method.body method_def in
  let method_return_type = Hhas_body.return_type method_body in
  let method_params = Hhas_body.params method_body in
  let env = Hhas_body.env method_body in
  let method_span = Hhas_method.span method_def in
  let method_is_async = Hhas_method.is_async method_def in
  let method_is_generator = Hhas_method.is_generator method_def in
  let method_is_pair_generator = Hhas_method.is_pair_generator method_def in
  let method_is_closure_body = Hhas_method.is_closure_body method_def in
  B.add_string buf "\n  .method ";
  B.add_string buf (method_attributes method_def);
  if Hhbc_options.source_mapping !Hhbc_options.compiler_options
  then B.add_string buf (string_of_span method_span ^ " ");
  B.add_string buf (string_of_type_info_option method_return_type);
  B.add_string buf (Hhbc_id.Method.to_raw_string method_name);
  B.add_string buf (string_of_params env method_params);
  if method_is_generator then B.add_string buf " isGenerator";
  if method_is_async then B.add_string buf " isAsync";
  if method_is_pair_generator then B.add_string buf " isPairGenerator";
  if method_is_closure_body then B.add_string buf " isClosureBody";
  B.add_string buf " {";
  add_body buf 4 method_body;
  B.add_string buf "  }"

let class_special_attributes c =
  let user_attrs = Hhas_class.attributes c in
  let attrs = Emit_adata.attributes_to_strings user_attrs in
  let attrs = if Emit_env.is_systemlib ()
    then "unique" :: "builtin" :: "persistent" :: attrs else attrs in
  let attrs = if not (Hhas_class.is_top c) then "nontop" :: attrs else attrs in
  let attrs =
    if Hhas_class.is_closure_class c && not @@ Emit_env.is_systemlib ()
    then "unique" :: attrs else attrs in
  let attrs =
    if Hhas_class.is_closure_class c then "no_override" :: attrs else attrs in
  let attrs = if Hhas_class.is_trait c then "trait" :: attrs else attrs in
  let attrs =
    if Hhas_class.is_interface c then "interface" :: attrs else attrs
  in
  let attrs = if Hhas_class.is_final c then "final" :: attrs else attrs in
  let attrs =
    if Hhas_class.enum_type c <> None then "enum" :: attrs else attrs
  in
  let attrs = if Hhas_class.is_abstract c then "abstract" :: attrs else attrs in
  let text = String.concat " " attrs in
  let text = if text = "" then "" else "[" ^ text ^ "] " in
  text

let add_extends buf class_base =
  match class_base with
  | None -> ()
  | Some name ->
    begin
      B.add_string buf " extends ";
      B.add_string buf (Hhbc_id.Class.to_raw_string name);
    end

let add_implements buf class_implements =
  match class_implements with
  | [] -> ()
  | _ ->
  begin
    B.add_string buf " implements (";
    B.add_string buf (String.concat " "
      (List.map Hhbc_id.Class.to_raw_string class_implements));
    B.add_string buf ")";
  end

let property_attributes p =
  let module P = Hhas_property in
  let attrs = [] in
  let attrs = if P.no_serialize p then "no_serialize" :: attrs else attrs in
  let attrs = if P.is_deep_init p then "deep_init" :: attrs else attrs in
  let attrs = if P.is_static p then "static" :: attrs else attrs in
  let attrs = if P.is_public p then "public" :: attrs else attrs in
  let attrs = if P.is_protected p then "protected" :: attrs else attrs in
  let attrs = if P.is_private p then "private" :: attrs else attrs in
  let text = String.concat " " attrs in
  let text = if text = "" then "" else "[" ^ text ^ "] " in
  text

let property_type_info p =
  let tinfo = Hhas_property.type_info p in
  (string_of_type_info ~is_enum:false tinfo) ^ " "

let property_doc_comment p =
  match Hhas_property.doc_comment p with
  | None -> ""
  | Some s -> Printf.sprintf "%s " (SU.triple_quote_string s)

let add_property class_def buf property =
  B.add_string buf "\n  .property ";
  B.add_string buf (property_attributes property);
  B.add_string buf (property_doc_comment property);
  B.add_string buf (property_type_info property);
  B.add_string buf (Hhbc_id.Prop.to_raw_string (Hhas_property.name property));
  B.add_string buf " =\n    ";
  let initial_value = Hhas_property.initial_value property in
  if Hhas_class.is_closure_class class_def
  || initial_value = Some Typed_value.Uninit
  then B.add_string buf "uninit;"
  else begin
    B.add_string buf "\"\"\"";
    let init = match initial_value with
      | None -> SS.str "N;"
      | Some value -> Emit_adata.adata_to_string_seq value
    in
    SS.add_string_from_seq buf init;
    B.add_string buf "\"\"\";"
  end

let add_constant buf c =
  let name = Hhas_constant.name c in
  let value = Hhas_constant.value c in
  B.add_string buf "\n  .const ";
  B.add_string buf name;
  begin match value with
  | Some Typed_value.Uninit ->
    B.add_string buf " = uninit"
  | Some value ->
    B.add_string buf " = \"\"\"";
    SS.add_string_from_seq buf @@ Emit_adata.adata_to_string_seq value;
    B.add_string buf "\"\"\""
  | None -> ()
    end;
  B.add_string buf ";"

let add_type_constant buf c =
  B.add_string buf "\n  .const ";
  B.add_string buf (Hhas_type_constant.name c);
  let initializer_t = Hhas_type_constant.initializer_t c in
  B.add_string buf " isType";
  match initializer_t with
  | Some init ->
    B.add_string buf " = \"\"\"";
    B.add_string buf @@ SS.seq_to_string @@
      Emit_adata.adata_to_string_seq init;
    B.add_string buf "\"\"\";"
  | None -> B.add_string buf ";"

let add_requirement buf r =
  B.add_string buf "\n  .require ";
  match r with
  | (Ast.MustExtend, name) ->
      B.add_string buf ("extends <" ^ name ^ ">;")
  | (Ast.MustImplement, name) ->
      B.add_string buf ("implements <" ^ name ^ ">;")

let add_enum_ty buf c =
  match Hhas_class.enum_type c with
  | Some et ->
    B.add_string buf "\n  .enum_ty ";
    B.add_string buf @@ string_of_type_info ~is_enum:true et;
    B.add_string buf ";"
  | _ -> ()

let add_use_precedence buf (id1, id2, ids) =
  let name = id1 ^ "::" ^ id2 in
  let unique_ids = List.fold_left ULS.add ULS.empty ids in
  let ids = String.concat " " @@ ULS.items unique_ids in
  B.add_string buf @@ Printf.sprintf "\n    %s insteadof %s;" name ids

let add_use_alias buf (ido1, id, ido2, kindl) =
  let aliasing_id =
    Option.value_map ~f:(fun id1 -> id1 ^ "::" ^ id) ~default:id ido1
  in
  let kind =
    match kindl with
    | [] -> None
    | x -> Some ("[" ^ (String.concat " " @@ List.map Ast.string_of_kind x ) ^ "]")
  in
  let rest = Option.merge kind ido2 ~f:(fun x y -> x ^ " " ^ y) in
  let rest = Option.value ~default:"" rest in
  B.add_string buf @@ Printf.sprintf "\n    %s as %s;" aliasing_id rest

let add_uses buf c =
  let use_l = Hhas_class.class_uses c in
  let use_alias_list = Hhas_class.class_use_aliases c in
  let use_precedence_list = Hhas_class.class_use_precedences c in
  if use_l = [] then () else
    begin
      let unique_ids =
        List.fold_left (fun l e -> ULS.add l (Utils.strip_ns e)) ULS.empty use_l
      in
      let use_l = String.concat " " @@ ULS.items unique_ids in
      B.add_string buf @@ Printf.sprintf "\n  .use %s" use_l;
      if use_alias_list = [] && use_precedence_list = []
      then B.add_char buf ';' else
      begin
        B.add_string buf " {";
        List.iter (add_use_precedence buf) use_precedence_list;
        List.iter (add_use_alias buf) use_alias_list;
        B.add_string buf "\n  }";
      end
    end

let add_class_def buf class_def =
  let class_name = Hhas_class.name class_def in
  (* TODO: user attributes *)
  B.add_string buf "\n.class ";
  B.add_string buf (class_special_attributes class_def);
  B.add_string buf (Hhbc_id.Class.to_raw_string class_name);
  if Hhbc_options.source_mapping !Hhbc_options.compiler_options
  then B.add_string buf (" " ^ string_of_span (Hhas_class.span class_def));
  add_extends buf (Hhas_class.base class_def);
  add_implements buf (Hhas_class.implements class_def);
  B.add_string buf " {";
  add_doc buf 2 (Hhas_class.doc_comment class_def);
  add_uses buf class_def;
  add_enum_ty buf class_def;
  List.iter (add_requirement buf) (Hhas_class.requirements class_def);
  List.iter (add_constant buf) (Hhas_class.constants class_def);
  List.iter (add_type_constant buf) (Hhas_class.type_constants class_def);
  List.iter (add_property class_def buf) (Hhas_class.properties class_def);
  List.iter (add_method_def buf) (Hhas_class.methods class_def);
  (* TODO: other members *)
  B.add_string buf "\n}\n"

let add_data_region_element buf argument =
  B.add_string buf ".adata ";
  B.add_string buf @@ (Hhas_adata.id argument);
  B.add_string buf " = \"\"\"";
  SS.add_string_from_seq buf
    @@ Emit_adata.adata_to_string_seq (Hhas_adata.value argument);
  B.add_string buf "\"\"\";\n"

let add_data_region buf adata =
  List.iter (add_data_region_element buf) adata;
  B.add_string buf "\n"

let add_top_level buf body =
  B.add_string buf ".main ";
  if Hhbc_options.source_mapping !Hhbc_options.compiler_options
  then B.add_string buf "(1,1) ";
  B.add_string buf "{";
  add_body buf 2 body;
  B.add_string buf "}\n"

let add_typedef buf typedef =
  let name = Hhas_typedef.name typedef in
  let type_info = Hhas_typedef.type_info typedef in
  let opt_ts = Hhas_typedef.type_structure typedef in
  B.add_string buf "\n.alias ";
  B.add_string buf (typedef_attributes typedef);
  B.add_string buf (Hhbc_id.Class.to_raw_string name);
  B.add_string buf (" = " ^ string_of_typedef_info type_info);
  match opt_ts with
  | Some ts ->
    B.add_string buf " \"\"\"";
    B.add_string buf @@ SS.seq_to_string @@
      Emit_adata.adata_to_string_seq ts;
    B.add_string buf "\"\"\";\n"
  | None ->
    B.add_string buf ";\n"

let add_include_region
    ?path ?doc_root ?search_paths ?include_roots ?(check_paths_exist=true)
    buf includes =
  let write_if_exists p =
    if not check_paths_exist || Sys.file_exists p
    then (B.add_string buf ("\n  " ^ p); true)
    else false in
  let write_include = function
    | Hhas_symbol_refs.Absolute p -> ignore @@ write_if_exists p
    | Hhas_symbol_refs.SearchPathRelative p ->
      if not check_paths_exist
      then B.add_string buf ("\n  " ^ p)
      else
        let rec try_paths = function
          | [] -> ()
          | prefix :: rest ->
            if write_if_exists (Filename.concat prefix p)
            then ()
            else try_paths rest in
        let dirname =
          Option.value_map path ~default:[] ~f:(fun p -> [Filename.dirname p]) in
        try_paths (dirname @ Option.value search_paths ~default:[])
    | Hhas_symbol_refs.DocRootRelative p -> ignore @@
      let resolved = Filename.concat (Option.value doc_root ~default:"") p in
      write_if_exists resolved
    | Hhas_symbol_refs.IncludeRootRelative (v, p) -> if p <> "" then
      Option.iter include_roots (fun irs ->
        Option.iter (SMap.find_opt v irs) (fun ir ->
          let resolved = Filename.concat ir p in
          ignore @@ write_if_exists resolved)) in
  if not (Hhas_symbol_refs.IncludePathSet.is_empty includes) then begin
    B.add_string buf "\n.includes {";
    Hhas_symbol_refs.IncludePathSet.iter write_include includes;
    B.add_string buf "\n}\n"
  end

let add_symbol_ref_regions buf symbol_refs =
  let add_region name refs =
    if not (SSet.is_empty refs) then begin
      B.add_string buf ("\n." ^ name);
      B.add_string buf " {";
      SSet.iter (fun s -> B.add_string buf ("\n  " ^ s)) refs;
      B.add_string buf "\n}\n";
    end in
  add_region "constant_refs" symbol_refs.Hhas_symbol_refs.constants;
  add_region "function_refs" symbol_refs.Hhas_symbol_refs.functions;
  add_region "class_refs" symbol_refs.Hhas_symbol_refs.classes

let add_program_content ?path dump_symbol_refs buf hhas_prog =
  let is_hh = if Hhas_program.is_hh hhas_prog then "1" else "0" in
  B.add_string buf @@ "\n.hh_file " ^ is_hh ^ ";\n";
  let functions = Hhas_program.functions hhas_prog in
  let top_level_body = Hhas_program.main hhas_prog in
  let classes = Hhas_program.classes hhas_prog in
  let adata = Hhas_program.adata hhas_prog in
  let symbol_refs = Hhas_program.symbol_refs hhas_prog in
  add_data_region buf adata;
  add_top_level buf top_level_body;
  List.iter (add_fun_def buf) functions;
  List.iter (add_class_def buf) classes;
  List.iter (add_typedef buf) (Hhas_program.typedefs hhas_prog);
  if dump_symbol_refs then begin
    add_include_region ?path buf symbol_refs.Hhas_symbol_refs.includes;
    add_symbol_ref_regions buf symbol_refs
  end

let add_program ?path dump_symbol_refs buf hhas_prog =
  let strict_types =
    match Hhas_program.strict_types hhas_prog with
    | Some true -> ".strict 1;\n\n"
    | Some false -> ".strict 0;\n\n"
    | None -> "" in
  match path with
  | Some p ->
    let p = Relative_path.to_absolute p in
    B.add_string buf
      (Printf.sprintf "# %s starts here\n\n%s.filepath \"%s\";\n" p strict_types p);
    add_program_content ~path:p dump_symbol_refs buf hhas_prog;
    B.add_string buf (Printf.sprintf "\n# %s ends here\n" p)
  | None ->
      B.add_string buf "#starts here\n";
      B.add_string buf strict_types;
      add_program_content dump_symbol_refs buf hhas_prog;
      B.add_string buf "\n#ends here\n"

let to_string ?path ?(dump_symbol_refs=false) hhas_prog =
  let buf = Buffer.create 1024 in
  add_program ?path dump_symbol_refs buf hhas_prog;
  B.contents buf
