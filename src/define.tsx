import {
  Action,
  ActionPanel,
  Icon,
  LaunchProps,
  List,
  LocalStorage,
  environment,
  open,
} from "@raycast/api";
import { execFile } from "child_process";
import { chmodSync } from "fs";
import { join } from "path";
import { promisify } from "util";
import { useCallback, useEffect, useState } from "react";

const execFileAsync = promisify(execFile);
const HELPER = join(environment.assetsPath, "dictd");
const HISTORY_KEY = "define-history";
const HISTORY_LIMIT = 25;
const DICT_PREF_KEY = "define-dictionary";

type DictInfo = { name: string; shortName: string };
type Entry = { word: string; definition: string | null; html?: string | null; source?: string | null };
type Lookup = { query: string; correct: boolean; results: Entry[]; engine?: string };

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

async function runHelper(args: string[]): Promise<string> {
  ensureHelper();
  const { stdout } = await execFileAsync(HELPER, args, { timeout: 8000, maxBuffer: 4 * 1024 * 1024 });
  return stdout;
}

async function listDictionaries(): Promise<DictInfo[]> {
  return JSON.parse(await runHelper(["dictionaries"])) as DictInfo[];
}

async function lookup(text: string, dictionary: string): Promise<Lookup> {
  const args = ["lookup"];
  if (dictionary) args.push("--dictionary", dictionary);
  args.push(text);
  return JSON.parse(await runHelper(args)) as Lookup;
}

/** Turn Dictionary.app HTML into readable markdown for the detail pane. */
function htmlToMarkdown(html: string): string {
  let s = html;
  s = s.replace(/<script[\s\S]*?<\/script>/gi, "");
  s = s.replace(/<style[\s\S]*?<\/style>/gi, "");
  s = s.replace(/<br\s*\/?>/gi, "\n");
  s = s.replace(/<\/(p|div|tr|li|h[1-6])>/gi, "\n");
  s = s.replace(/<h[1-6][^>]*>/gi, "\n### ");
  s = s.replace(/<li[^>]*>/gi, "\n- ");
  s = s.replace(/<(b|strong)(?:\s[^>]*)?>/gi, "**");
  s = s.replace(/<\/(b|strong)>/gi, "**");
  s = s.replace(/<(i|em|dfn)(?:\s[^>]*)?>/gi, "_");
  s = s.replace(/<\/(i|em|dfn)>/gi, "_");
  s = s.replace(/<[^>]+>/g, "");
  s = s
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'");
  s = s.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  return s;
}

// DCSCopyTextDefinition returns one long line: "word | pronunciation | noun 1 sense…"
function textToMarkdown(word: string, definition: string): string {
  let body = definition.trim();
  if (body.toLowerCase().startsWith(word.toLowerCase())) {
    const rest = body.slice(word.length);
    if (!/^[A-Za-z]/.test(rest)) body = rest.trim();
  }
  return body
    .replace(/\s\|\s([^|]+)\s\|\s/, " _/$1/_\n\n")
    .replace(/\s(\d+)\s(?=[A-Za-z(\[])/g, "\n\n**$1** ")
    .replace(/\s•\s/g, "\n- ")
    .replace(
      /\s(PHRASES|PHRASAL VERBS|DERIVATIVES|ORIGIN|USAGE|SYNONYMS|ANTONYMS|RELATED WORDS|WORD HISTORY)\s/g,
      "\n\n### $1\n\n",
    )
    .replace(/\s(noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection|exclamation)\s/gi, "\n\n_$1_\n\n");
}

function toMarkdown(entry: Entry): string {
  const source = entry.source ? `\n\n— _${entry.source}_` : "";
  if (entry.html) {
    const body = htmlToMarkdown(entry.html);
    if (body) return `# ${entry.word}\n\n${body}${source}`;
  }
  if (!entry.definition) return `# ${entry.word}\n\n_No definition in the macOS dictionary._`;
  return `# ${entry.word}\n\n${textToMarkdown(entry.word, entry.definition)}${source}`;
}

function firstSense(definition: string | null): string {
  if (!definition) return "No definition found";
  const afterPron = definition.replace(/^[^|]*\|[^|]*\|\s*/, "");
  return afterPron.replace(/\s+/g, " ").slice(0, 110);
}

async function loadHistory(): Promise<string[]> {
  const raw = await LocalStorage.getItem<string>(HISTORY_KEY);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

async function pushHistory(word: string): Promise<string[]> {
  const trimmed = word.trim();
  if (!trimmed) return loadHistory();
  const prev = await loadHistory();
  const next = [trimmed, ...prev.filter((w) => w.toLowerCase() !== trimmed.toLowerCase())].slice(0, HISTORY_LIMIT);
  await LocalStorage.setItem(HISTORY_KEY, JSON.stringify(next));
  return next;
}

export default function Command(props: LaunchProps<{ arguments: { word?: string } }>) {
  const [query, setQuery] = useState(props.arguments?.word ?? "");
  const [dictionary, setDictionary] = useState("");
  const [dictionaries, setDictionaries] = useState<DictInfo[]>([]);
  const [dictLoadError, setDictLoadError] = useState<string | null>(null);
  const [data, setData] = useState<Lookup | null>(null);
  const [history, setHistory] = useState<string[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [dictsResult, hist, savedDict] = await Promise.all([
        listDictionaries()
          .then((dicts) => ({ dicts, error: null as string | null }))
          .catch((e: unknown) => ({
            dicts: [] as DictInfo[],
            error: e instanceof Error ? e.message : String(e),
          })),
        loadHistory(),
        LocalStorage.getItem<string>(DICT_PREF_KEY),
      ]);
      if (cancelled) return;
      setDictionaries(dictsResult.dicts);
      setDictLoadError(
        dictsResult.error
          ? dictsResult.error
          : dictsResult.dicts.length === 0
            ? "dictd dictionaries returned no sources — rebuild assets/dictd"
            : null,
      );
      setHistory(hist);
      if (savedDict && (savedDict === "" || dictsResult.dicts.some((d) => d.name === savedDict))) {
        setDictionary(savedDict);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const onDictionaryChange = useCallback((value: string) => {
    setDictionary(value);
    void LocalStorage.setItem(DICT_PREF_KEY, value);
  }, []);

  useEffect(() => {
    const text = query.trim();
    if (!text) {
      setData(null);
      setIsLoading(false);
      return;
    }
    let cancelled = false;
    setIsLoading(true);
    lookup(text, dictionary)
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
  }, [query, dictionary]);

  const results = data?.results ?? [];
  const misspelled = data ? !data.correct : false;
  const showingHistory = !query.trim() && history.length > 0;
  // Only hard-block on a proven stale lookup engine. Dictionary list failures are soft.
  const staleHelper = Boolean(data && data.engine !== "sounds-1");
  const staleReason =
    data && data.engine !== "sounds-1"
      ? "Lookup helper is missing engine “sounds-1” — assets/dictd is outdated."
      : null;

  const remember = useCallback((word: string) => {
    void pushHistory(word).then(setHistory);
  }, []);

  return (
    <List
      isLoading={isLoading}
      searchText={query}
      onSearchTextChange={setQuery}
      throttle
      isShowingDetail={results.length > 0}
      searchBarPlaceholder="Type a word to define"
      searchBarAccessory={
        <List.Dropdown tooltip="Dictionary" value={dictionary} onChange={onDictionaryChange}>
          <List.Dropdown.Item
            title={dictLoadError ? "All Dictionaries (sources unavailable)" : "All Dictionaries"}
            value=""
          />
          {dictionaries.map((d) => (
            <List.Dropdown.Item key={d.name} title={d.name} value={d.name} />
          ))}
        </List.Dropdown>
      }
    >
      {error ? (
        <List.EmptyView icon={Icon.Warning} title="Dictionary helper failed" description={error} />
      ) : staleHelper ? (
        <List.EmptyView
          icon={Icon.Warning}
          title="Stale dictionary helper"
          description={`${staleReason ?? "assets/dictd is outdated."}\n\nOn macOS run:\nswiftc -O -o assets/dictd helper/dictd.swift && npm run build\nThen reinstall the build/ folder in Tinycast.`}
        />
      ) : showingHistory ? (
        <List.Section title="Recent" subtitle={`${history.length}`}>
          {history.map((word) => (
            <List.Item
              key={word}
              id={`history-${word}`}
              title={word}
              icon={Icon.Clock}
              actions={
                <ActionPanel>
                  <Action title="Look Up" icon={Icon.Book} onAction={() => { remember(word); setQuery(word); }} />
                  <Action
                    title="Remove from History"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    onAction={() => {
                      void (async () => {
                        const next = (await loadHistory()).filter((w) => w !== word);
                        await LocalStorage.setItem(HISTORY_KEY, JSON.stringify(next));
                        setHistory(next);
                      })();
                    }}
                  />
                  <Action
                    title="Clear History"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    onAction={() => {
                      void LocalStorage.removeItem(HISTORY_KEY).then(() => setHistory([]));
                    }}
                  />
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      ) : !query.trim() ? (
        <List.EmptyView
          icon={Icon.Book}
          title="Dictionary"
          description="Type a word. Close typos and sound-alikes are suggested as you go."
        />
      ) : results.length === 0 && !isLoading ? (
        <List.EmptyView
          icon={Icon.QuestionMark}
          title="No matches"
          description={`Nothing in the dictionary resembles “${query.trim()}”.`}
        />
      ) : (
        <List.Section title={misspelled ? "Did you mean" : "Definitions"} subtitle={`${results.length}`}>
          {results.map((entry) => (
            <List.Item
              key={entry.word}
              id={entry.word}
              title={entry.word}
              subtitle={firstSense(entry.definition)}
              accessories={entry.source ? [{ text: entry.source }] : undefined}
              icon={entry.definition || entry.html ? Icon.Book : Icon.Text}
              detail={<List.Item.Detail markdown={toMarkdown(entry)} />}
              actions={
                <ActionPanel>
                  <ActionPanel.Section>
                    <Action.CopyToClipboard
                      title="Copy Word"
                      content={entry.word}
                      onCopy={() => remember(entry.word)}
                    />
                    <Action.Paste title="Paste Word" content={entry.word} onPaste={() => remember(entry.word)} />
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
                      onAction={() => {
                        remember(entry.word);
                        void open(`dict://${encodeURIComponent(entry.word)}`);
                      }}
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
