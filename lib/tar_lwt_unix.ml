(*
 * Copyright (C) 2006-2013 Citrix Systems Inc.
 * Copyright (C)      2012 Thomas Gazagnaire <thomas@ocamlpro.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Lwt

let debug_io = ref false

let complete name op fd buffer =
  if !debug_io
  then Printf.fprintf stderr "%s length=%d\n%!" name (Cstruct.len buffer);
  let ofs = buffer.Cstruct.off in
  let len = buffer.Cstruct.len in
  let buf = buffer.Cstruct.buffer in
  let rec loop acc fd buf ofs len =
    op fd buf ofs len >>= fun n ->
    let len' = len - n in
    let acc' = acc + n in
    if len' = 0 || n = 0
    then return acc'
    else loop acc' fd buf (ofs + n) len' in
  loop 0 fd buf ofs len >>= fun n ->
  if n = 0 && len <> 0
  then fail End_of_file
  else return ()

let really_read = complete "read" Lwt_bytes.read
let really_write = complete "write" Lwt_bytes.write

let copy_n ifd ofd n =
  let block_size = 32768 in
  let buffer = Cstruct.create block_size in
  let rec loop remaining =
    if remaining = 0L then return () else begin
      let this = Int64.(to_int (min (of_int block_size) remaining)) in
      let block = Cstruct.sub buffer 0 this in
      really_read ifd block >>= fun () ->
      really_write ofd block >>= fun () ->
      loop (Int64.(sub remaining (of_int this)))
    end in
  loop n

module Header = struct
  include Tar.Header

  (** Returns the next header block or None if two consecutive
      zero-filled blocks are discovered. Assumes stream is positioned at the
      possible start of a header block. End_of_file is thrown if the stream
      unexpectedly fails *)
  let get_next_header (ifd: Lwt_unix.file_descr) : t option Lwt.t = 
    let next () =
      let buffer = Cstruct.create length in
      really_read ifd buffer >>= fun () ->
      return (unmarshal buffer)
    in
    next () >>= function
    | Some x -> return (Some x)
    | None -> 
	begin next () >>= function
	| Some x -> return (Some x)
	| None -> return None
	end
	  
  (** Return the header needed for a particular file on disk *)
  let of_file (file: string) : t Lwt.t =
    Lwt_unix.LargeFile.stat file >>= fun stat ->
    return { file_name   = file;
      file_mode   = stat.Lwt_unix.LargeFile.st_perm;
      user_id     = stat.Lwt_unix.LargeFile.st_uid;
      group_id    = stat.Lwt_unix.LargeFile.st_gid;
      file_size   = stat.Lwt_unix.LargeFile.st_size;
      mod_time    = Int64.of_float stat.Lwt_unix.LargeFile.st_mtime;
      link_indicator = Link.Normal;
      link_name   = "" }
end

let write_block (header: Tar.Header.t) (body: Lwt_unix.file_descr -> unit Lwt.t) (fd : Lwt_unix.file_descr) = 
  let buffer = Cstruct.create Tar.Header.length in
  Tar.Header.marshal buffer header;
  really_write fd buffer >>= fun () ->
  body fd >>= fun () ->
  really_write fd (Tar.Header.zero_padding header)

let write_end (fd: Lwt_unix.file_descr) =
  really_write fd Tar.Header.zero_block >>= fun () ->
  really_write fd Tar.Header.zero_block

(** Utility functions for operating over whole tar archives *)
module Archive = struct

  (** Skip 'n' bytes from input channel 'ifd' *)
  let skip (ifd: Lwt_unix.file_descr) (n: int) =
    let buffer_size = 32768 in
    let buffer = Cstruct.create buffer_size in
    let rec loop (n: int) = 
      if n <= 0 then return ()
      else 
	let amount = min n buffer_size in
        let block = Cstruct.sub buffer 0 amount in
        really_read ifd block >>= fun () ->
	loop (n - amount) in
    loop n

  (** Read the next header, apply the function 'f' to the fd and the header. The function
      should leave the fd positioned immediately after the datablock. Finally the function
      skips past the zero padding to the next header *)
  let with_next_file (fd: Lwt_unix.file_descr) (f: Lwt_unix.file_descr -> Tar.Header.t -> 'a Lwt.t) = 
    Header.get_next_header fd >>= function
    | Some hdr ->
      f fd hdr >>= fun result ->
      skip fd (Tar.Header.compute_zero_padding_length hdr) >>= fun () ->
      return (Some result)
    | None ->
      return None

  (** List the contents of a tar *)
  let list fd = 
    let rec loop acc = Header.get_next_header fd >>= function
    | None -> return (List.rev acc)
    | Some hdr ->
      skip fd (Int64.to_int hdr.Tar.Header.file_size) >>= fun () ->
      skip fd (Tar.Header.compute_zero_padding_length hdr) >>= fun () ->
      loop (hdr :: acc) in
    loop []

  (** Extract the contents of a tar to directory 'dest' *)
  let extract dest ifd = 
    let rec loop () = Header.get_next_header ifd >>= function
    | None -> return ()
    | Some hdr ->
	let filename = dest hdr.Tar.Header.file_name in
	print_endline filename;
	Lwt_unix.openfile filename [Unix.O_WRONLY] 0644 >>= fun ofd ->
	copy_n ifd ofd hdr.Tar.Header.file_size >>= fun () ->
	skip ifd (Tar.Header.compute_zero_padding_length hdr) >>= fun () ->
        loop () in
    loop ()

  (** Create a tar on file descriptor fd from the filename list
      'files' *)
  let create files ofd = 
    let file filename = 
      Lwt_unix.stat filename >>= fun stat ->
      if stat.Unix.st_kind <> Unix.S_REG then begin
        Printf.eprintf "Skipping %s: not a regular file\n" filename;
        return ()
      end else begin
	Header.of_file filename >>= fun hdr ->

	write_block hdr (fun ofd ->
	  Lwt_unix.openfile filename [Unix.O_RDONLY] 0644 >>= fun ifd ->
	  copy_n ifd ofd hdr.Tar.Header.file_size
        ) ofd
      end in
    Lwt_list.iter_s file files >>= fun () ->
    (* Add two empty blocks *)
    write_end ofd
  
end
