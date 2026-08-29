// The fixed half of a transform worker: reads one JSON event per line on
// stdin, hands it to the user's `transform`, writes one JSON line back.
// The user's script exports `transform(event) -> event | null`; a thrown
// error becomes {"error": message} for that event and the worker goes on.
import * as std from "qjs:std";
import { transform } from "./user.js";

let line;
while ((line = std.in.getline()) !== null) {
  let out;
  try {
    const event = JSON.parse(line);
    const result = transform(event);
    out = { ok: result === undefined ? null : result };
  } catch (e) {
    out = { error: String(e && e.message ? e.message : e) };
  }
  std.out.puts(JSON.stringify(out) + "\n");
}
