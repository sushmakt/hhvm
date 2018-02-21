(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

open Hh_core

type t = {
  attribute_name          : Litstr.id;
  attribute_arguments     : Typed_value.t list
}

let make attribute_name attribute_arguments =
  { attribute_name; attribute_arguments }

let name a = a.attribute_name
let arguments a = a.attribute_arguments

let is_x s attributes =
  let f attr = (name attr) = s in
  List.exists attributes f
let is_memoized = is_x "__Memoize"
let is_native = is_x "__Native"

let deprecation_info attributes =
  let f attr =
    if (name attr) = "__Deprecated" then Some (arguments attr) else None
  in
  List.find_map attributes f
