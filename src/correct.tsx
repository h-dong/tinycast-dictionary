import { Clipboard, environment, getSelectedText, showHUD, showToast, Toast } from "@raycast/api";
import { execFile } from "child_process";
import { chmodSync } from "fs";
import { join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);
const HELPER = join(environment.assetsPath, "dictd");

type Correction = { original: string; corrected: string; changes: { from: string; to: string }[] };

export default async function Command() {
  try {
    chmodSync(HELPER, 0o755);
  } catch {
    // ignore; exec will report a real problem
  }

  let text = "";
  let fromClipboard = false;
  try {
    text = await getSelectedText();
  } catch {
    text = (await Clipboard.readText()) ?? "";
    fromClipboard = true;
  }
  if (!text.trim()) {
    await showHUD("Select some text to correct");
    return;
  }

  let result: Correction;
  try {
    const { stdout } = await execFileAsync(HELPER, ["correct", text], { timeout: 10000, maxBuffer: 4 * 1024 * 1024 });
    result = JSON.parse(stdout) as Correction;
  } catch (e) {
    await showToast({ style: Toast.Style.Failure, title: "Spellcheck failed", message: e instanceof Error ? e.message : String(e) });
    return;
  }

  if (result.changes.length === 0) {
    await showHUD("No spelling mistakes");
    return;
  }

  if (fromClipboard) {
    await Clipboard.copy(result.corrected);
  } else {
    await Clipboard.paste(result.corrected);
  }

  const summary = result.changes
    .slice(0, 3)
    .map((c) => `${c.from} → ${c.to}`)
    .join(", ");
  const more = result.changes.length > 3 ? ` +${result.changes.length - 3}` : "";
  await showHUD(`Fixed ${result.changes.length} word${result.changes.length === 1 ? "" : "s"}: ${summary}${more}${fromClipboard ? " (copied)" : ""}`);
}
