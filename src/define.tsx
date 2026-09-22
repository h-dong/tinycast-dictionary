import { Action, ActionPanel, Icon, LaunchProps, List, environment, open } from "@raycast/api";
import { execFile } from "child_process";
import { chmodSync } from "fs";
import { join } from "path";
import { promisify } from "util";
import { useEffect, useState } from "react";

const execFileAsync = promisify(execFile);
const HELPER = join(environment.assetsPath, "dictd");

type Entry = { word: string; definition: string | null };
type Lookup = { query: string; correct: boolean; results: Entry[] };

let helperReady = false;
function ensureHelper() {
  if (helperReady) return;
  try {
    chmodSync(HELPER, 0o755);
  } catch {
    // Already executable or read-only location; exec will surface a real error.
  }
  helperReady = true;
}

async function lookup(text: string): Promise<Lookup> {
  ensureHelper();
  const { stdout } = await execFileAsync(HELPER, ["lookup", text], { timeout: 5000 });
  return JSON.parse(stdout) as Lookup;
}

// DCSCopyTextDefinition returns one long line: "word | pronunciation | noun 1 sense… 2 sense… • sub-sense…"
// Break it into readable markdown.
function toMarkdown(entry: Entry): string {
  if (!entry.definition) return `# ${entry.word}\n\n_No definition in the macOS dictionary._`;
  let body = entry.definition.trim();
  // Drop the leading headword so it isn't repeated under the heading.
  // Don't strip a prefix of a longer headword ("uninstal" vs "uninstall" → leftover "l").
  if (body.toLowerCase().startsWith(entry.word.toLowerCase())) {
    const rest = body.slice(entry.word.length);
    if (!/^[A-Za-z]/.test(rest)) body = rest.trim();
  }
  body = body
    .replace(/\s\|\s([^|]+)\s\|\s/, " _/$1/_\n\n") // pronunciation
    .replace(/\s(\d+)\s(?=[A-Za-z(\[])/g, "\n\n**$1** ") // numbered senses
    .replace(/\s•\s/g, "\n- ") // sub-senses
    .replace(/\s(PHRASES|PHRASAL VERBS|DERIVATIVES|ORIGIN|USAGE)\s/g, "\n\n### $1\n\n");
  return `# ${entry.word}\n\n${body}`;
}

function firstSense(definition: string | null): string {
  if (!definition) return "No definition found";
  const afterPron = definition.replace(/^[^|]*\|[^|]*\|\s*/, "");
  return afterPron.replace(/\s+/g, " ").slice(0, 110);
}

export default function Command(props: LaunchProps<{ arguments: { word?: string } }>) {
  const [query, setQuery] = useState(props.arguments?.word ?? "");
  const [data, setData] = useState<Lookup | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const text = query.trim();
    if (!text) {
      setData(null);
      setIsLoading(false);
      return;
    }
    let cancelled = false;
    setIsLoading(true);
    lookup(text)
      .then((res) => {
        if (cancelled) return;
        setData(res);
        setError(null);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [query]);

  const results = data?.results ?? [];
  const misspelled = data ? !data.correct : false;

  return (
    <List
      isLoading={isLoading}
      searchText={query}
      onSearchTextChange={setQuery}
      throttle
      isShowingDetail={results.length > 0}
      searchBarPlaceholder="Type a word to define"
    >
      {error ? (
        <List.EmptyView icon={Icon.Warning} title="Dictionary helper failed" description={error} />
      ) : !query.trim() ? (
        <List.EmptyView icon={Icon.Book} title="Dictionary" description="Type a word. Close typos are suggested as you go." />
      ) : results.length === 0 && !isLoading ? (
        <List.EmptyView icon={Icon.QuestionMark} title="No matches" description={`Nothing in the dictionary resembles “${query.trim()}”.`} />
      ) : (
        <List.Section title={misspelled ? "Did you mean" : "Definitions"} subtitle={`${results.length}`}>
          {results.map((entry) => (
            <List.Item
              key={entry.word}
              id={entry.word}
              title={entry.word}
              subtitle={firstSense(entry.definition)}
              icon={entry.definition ? Icon.Book : Icon.Text}
              detail={<List.Item.Detail markdown={toMarkdown(entry)} />}
              actions={
                <ActionPanel>
                  <ActionPanel.Section>
                    <Action.CopyToClipboard title="Copy Word" content={entry.word} />
                    <Action.Paste title="Paste Word" content={entry.word} />
                    {entry.definition ? (
                      <Action.CopyToClipboard
                        title="Copy Definition"
                        content={entry.definition}
                        shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
                      />
                    ) : null}
                  </ActionPanel.Section>
                  <ActionPanel.Section>
                    <Action
                      title="Open in Dictionary.app"
                      icon={Icon.AppWindow}
                      shortcut={{ modifiers: ["cmd"], key: "o" }}
                      onAction={() => open(`dict://${encodeURIComponent(entry.word)}`)}
                    />
                  </ActionPanel.Section>
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}
