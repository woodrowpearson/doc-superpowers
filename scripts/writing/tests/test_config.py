"""The writing configuration: the defaults, a project's file merged over them, the register each
file gets, and the code patterns the work ledger adds. Every project, folder and code here is
invented."""

from __future__ import annotations

import json
import re
import tempfile
import unittest
from pathlib import Path

from tests import support

config = support.load("config")
markdown = support.load("markdown")

CONFIG = "docs/writing/config.json"
LEDGER_CONFIG = "docs/ledger/config.json"
REGISTRY = "docs/ledger/ledgers.json"


def put(root: Path, files: dict[str, str]) -> None:
    """Write ``files`` under ``root`` without committing them."""
    for name, text in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))


def project(settings: object) -> dict[str, str]:
    return {CONFIG: json.dumps(settings)}


def ledgers(*ids: str) -> dict[str, str]:
    """A ledger switched on, with one active ledger per id."""
    registry = {"schema": "ledger-registry/1",
                "ledgers": [{"id": name, "title": name.title(), "kind": "service",
                             "status": "active", "scope": "x"} for name in ids]}
    return {LEDGER_CONFIG: "{}", REGISTRY: json.dumps(registry)}


def index(**types: str) -> dict:
    """The ``docs`` object of a doc-index: each keyword names a path (with ``__`` for ``/`` and
    ``_md`` for ``.md``), its value the ``doc_type``."""
    return {name.replace("__", "/").replace("_md", ".md"): {"doc_type": doc_type}
            for name, doc_type in types.items()}


class Defaults(unittest.TestCase):
    def test_defaults_alone_give_the_documented_limits(self) -> None:
        with support.git_repo() as repo:
            loaded = config.load(repo)

        self.assertEqual(loaded.limits["terse"], config.Limits(35, 50, 2))
        self.assertEqual(loaded.limits["full"], config.Limits(40, None, None))
        self.assertTrue(loaded.enabled)

    def test_the_defaults_hold_the_code_shapes_the_words_and_the_skipped_prefixes(self) -> None:
        with support.git_repo() as repo:
            loaded = config.load(repo)

        codes = loaded.codes
        self.assertEqual(len(codes.patterns), 4)
        self.assertTrue(all(isinstance(pattern, re.Pattern) for pattern in codes.patterns))
        self.assertTrue({"P0", "Q4", "UTF-8", "SHA-256", "C4"} <= codes.allowed)
        self.assertEqual(codes.gloss_chars, frozenset({"'", '"', "’", "`", "*"}))
        self.assertEqual(loaded.skip_prefixes, ("Ledger-Claims:", "Co-Authored-By:"))
        self.assertEqual(loaded.skip_blocks, ("Implementation:", "Realized-by:"))

    def test_the_default_patterns_find_each_code_shape(self) -> None:
        with support.git_repo() as repo:
            codes = config.load(repo).codes

        text = "see ORB-12, KX7, beacon-~a1c9, #318, and a2b-~00ff00ff but not C4 or plain words"
        self.assertEqual(markdown.bare_codes(text, codes),
                         ["ORB-12", "KX7", "beacon-~a1c9", "#318", "a2b-~00ff00ff"])

    def test_the_provisional_pattern_stops_at_sixteen_name_characters_and_eight_digits(self) -> None:
        with support.git_repo() as repo:
            codes = config.load(repo).codes

        self.assertEqual(markdown.bare_codes("abcdefghijklmnop-~abcd1234", codes),
                         ["abcdefghijklmnop-~abcd1234"])
        self.assertEqual(markdown.bare_codes("abcdefghijklmnopq-~abcd1234", codes), [])
        self.assertEqual(markdown.bare_codes("orbit-~abcd12345", codes), [])

    def test_a_missing_project_file_is_not_an_error_outside_a_repository(self) -> None:
        with tempfile.TemporaryDirectory() as empty:
            loaded = config.load(Path(empty))

        self.assertEqual(loaded.limits["terse"].sentence, 35)


class ProjectFile(unittest.TestCase):
    def test_a_project_file_overrides_key_by_key(self) -> None:
        with support.git_repo() as repo:
            put(repo, project({"limits": {"full": {"sentence": 30}}}))

            loaded = config.load(repo)

        self.assertEqual(loaded.limits["full"], config.Limits(30, None, None))
        self.assertEqual(loaded.limits["terse"], config.Limits(35, 50, 2))
        self.assertTrue(loaded.enabled)

    def test_a_null_removes_a_limit_the_defaults_set(self) -> None:
        with support.git_repo() as repo:
            put(repo, project({"limits": {"terse": {"item": None}}}))

            loaded = config.load(repo)

        self.assertEqual(loaded.limits["terse"], config.Limits(35, None, 2))

    def test_enabled_false_is_read(self) -> None:
        with support.git_repo() as repo:
            put(repo, project({"enabled": False}))

            loaded = config.load(repo)

        self.assertFalse(loaded.enabled)

    def test_lists_add_to_the_defaults(self) -> None:
        with support.git_repo() as repo:
            put(repo, project({
                "codes": {"patterns": [r"(?<![A-Za-z0-9_])TKT/[0-9]+"], "allowed": ["TKT/0"],
                          "gloss_chars": ["~"]},
                "skip_prefixes": ["Reviewed-by:"], "skip_blocks": ["Steps:"]}))

            loaded = config.load(repo)

        self.assertEqual(len(loaded.codes.patterns), 5)
        self.assertEqual(markdown.bare_codes("see TKT/21 and ORB-12", loaded.codes),
                         ["TKT/21", "ORB-12"])
        self.assertTrue({"TKT/0", "UTF-8"} <= loaded.codes.allowed)
        self.assertEqual(loaded.codes.gloss_chars, frozenset({"'", '"', "’", "`", "*", "~"}))
        self.assertEqual(loaded.skip_prefixes, ("Ledger-Claims:", "Co-Authored-By:",
                                                "Reviewed-by:"))
        self.assertEqual(loaded.skip_blocks, ("Implementation:", "Realized-by:", "Steps:"))

    def test_skip_blocks_add_to_the_defaults_without_repeating_them(self) -> None:
        cases = (
            ("a header already in the defaults", ["Realized-by:", "Steps:"],
             ("Implementation:", "Realized-by:", "Steps:")),
            ("an empty list", [], ("Implementation:", "Realized-by:")),
        )
        for name, listed, expected in cases:
            with self.subTest(name), support.git_repo() as repo:
                put(repo, project({"skip_blocks": listed}))

                loaded = config.load(repo)

                self.assertEqual(loaded.skip_blocks, expected)
                self.assertEqual(loaded.skip_prefixes, ("Ledger-Claims:", "Co-Authored-By:"))

    def test_project_registers_win_over_the_defaults(self) -> None:
        with support.git_repo() as repo:
            put(repo, project({"registers": {
                "doc_types": {"runbook": "terse", "guide": "terse"},
                "paths": [{"prefix": "ops/", "register": "terse"},
                          {"prefix": "docs/guides/", "register": "terse"}]}}))

            loaded = config.load(repo)

        self.assertEqual(loaded.doc_types["runbook"], "terse")
        self.assertEqual(loaded.doc_types["guide"], "terse")
        self.assertEqual(loaded.doc_types["plan"], "terse")
        self.assertEqual(config.register_for("ops/rota.md", loaded, None), "terse")
        self.assertEqual(config.register_for("docs/guides/start.md", loaded, None), "terse")
        self.assertEqual(config.register_for("docs/notes/start.md", loaded, None), "full")
        self.assertEqual(config.register_for("docs/x.md", loaded, index(docs__x_md="runbook")),
                         "terse")

    def test_a_path_rule_may_name_a_register_none_to_leave_files_alone(self) -> None:
        with support.git_repo() as repo:
            put(repo, project({"registers": {"paths": [
                {"prefix": "docs/generated/", "register": None}]}}))

            loaded = config.load(repo)

        self.assertIsNone(config.register_for("docs/generated/api.md", loaded, None))
        self.assertEqual(config.register_for("docs/notes/api.md", loaded, None), "full")

    def test_a_byte_order_mark_is_not_part_of_the_json(self) -> None:
        with support.git_repo() as repo:
            (repo / "docs" / "writing").mkdir(parents=True)
            (repo / CONFIG).write_bytes("﻿{\"enabled\": false}\n".encode("utf-8"))

            self.assertFalse(config.load(repo).enabled)

    def test_the_file_is_read_from_a_revision_when_one_is_given(self) -> None:
        with support.git_repo() as repo:
            support.commit(repo, {"README.md": "x\n"}, "first")
            base = support.commit(repo, project({"limits": {"full": {"sentence": 25}}}), "config")
            put(repo, project({"limits": {"full": {"sentence": 20}}}))

            at_base = config.load(repo, base)
            at_first = config.load(repo, base + "~1")
            working = config.load(repo)

        self.assertEqual(at_base.limits["full"].sentence, 25)
        self.assertEqual(at_first.limits["full"].sentence, 40)
        self.assertEqual(working.limits["full"].sentence, 20)

    def test_a_revision_git_cannot_resolve_is_malformed_not_a_traceback(self) -> None:
        with support.git_repo() as repo:
            support.commit(repo, {"README.md": "x\n"}, "first")

            for rev in ("no-such-rev", "-x"):
                with self.subTest(rev=rev), self.assertRaises(config.Malformed) as caught:
                    config.load(repo, rev)
                self.assertIn(rev, str(caught.exception))


class Registers(unittest.TestCase):
    def setUp(self) -> None:
        with support.git_repo() as repo:
            self.config = config.load(repo)

    def register(self, path: str, docs: dict | None = None) -> str | None:
        return config.register_for(path, self.config, docs)

    def test_doc_type_wins_over_path(self) -> None:
        self.assertEqual(self.register("docs/notes/x.md", index(docs__notes__x_md="plan")),
                         "terse")
        self.assertEqual(self.register("docs/plans/x.md", index(docs__plans__x_md="guide")),
                         "full")
        self.assertEqual(self.register("docs/plans/x.md", {}), "terse")

    def test_plans_issues_and_audits_are_terse_the_rest_full(self) -> None:
        terse = ("plan", "issue", "audit")
        full = ("design-spec", "spec", "adr", "architecture", "api-contracts", "data-layer",
                "infra", "ci-cd", "workflows", "agentic", "guide", "codebase-guide",
                "conventions")
        for doc_type in terse + full:
            with self.subTest(doc_type=doc_type):
                self.assertEqual(self.register("notes/x.md", {"notes/x.md": {"doc_type": doc_type}}),
                                 "terse" if doc_type in terse else "full")

    def test_an_unknown_doc_type_is_full(self) -> None:
        docs = index(docs__plans__x_md="reference")

        self.assertEqual(self.register("docs/plans/x.md", docs), "full")

    def test_an_entry_without_a_doc_type_falls_back_to_the_path(self) -> None:
        for entry in ({}, {"doc_type": None}, {"doc_type": ""}, "not an object"):
            with self.subTest(entry=entry):
                self.assertEqual(self.register("docs/plans/x.md", {"docs/plans/x.md": entry}),
                                 "terse")

    def test_markdown_outside_the_paths_is_not_linted(self) -> None:
        self.assertIsNone(self.register("README.md"))
        self.assertIsNone(self.register("src/notes/design.md"))
        self.assertIsNone(self.register("CHANGELOG.md"))

    def test_the_default_path_rules(self) -> None:
        cases = {
            "AGENTS.md": "terse",
            "CLAUDE.md": "terse",
            "packages/api/CLAUDE.md": "terse",
            "docs/AGENTS.md": "terse",
            "docs/plans/2026-01-01-orbit.md": "terse",
            "docs/plans/2026-01-01-orbit-design.md": "full",
            "docs/plans/deep/orbit-design.md": "full",
            "docs/issues/2026-01-01-leak.md": "terse",
            "docs/guides/start.md": "full",
            "docs/architecture/system.md": "full",
            "docs/archive/plans/old.md": None,
            "docs/archive/x.md": None,
            "docs/diagrams/system.png": None,
            "docs/notes/x.txt": None,
            "NOT-AGENTS.md": None,
            "docs/MYCLAUDE.md": "full",
            "./docs/guides/start.md": "full",
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.register(path), expected)

    def test_an_archived_doc_with_a_type_is_not_linted(self) -> None:
        docs = index(docs__archive__specs__old_md="spec", docs__archive__plans__old_md="plan")

        self.assertIsNone(self.register("docs/archive/specs/old.md", docs))
        self.assertIsNone(self.register("docs/archive/plans/old.md", docs))
        self.assertTrue(config.is_record("docs/archive/specs/old.md", docs))
        self.assertTrue(config.is_record("docs/archive/plans/old.md", docs))

    def test_a_non_markdown_file_is_not_linted_even_when_the_index_types_it(self) -> None:
        docs = {"docs/api/openapi.yaml": {"doc_type": "api-contracts"}}

        self.assertIsNone(self.register("docs/api/openapi.yaml", docs))

    def test_no_index_means_the_path_rules_alone(self) -> None:
        self.assertEqual(self.register("docs/plans/x.md", None), "terse")

    def test_records_are_plan_issue_audit_design_spec_and_archive(self) -> None:
        docs = index(docs__a_md="plan", docs__b_md="issue", docs__c_md="audit",
                     docs__d_md="design-spec", docs__e_md="spec", docs__f_md="guide",
                     docs__g_md="reference")
        for name in "abcd":
            with self.subTest(name=name):
                self.assertTrue(config.is_record(f"docs/{name}.md", docs))
        for name in "efg":
            with self.subTest(name=name):
                self.assertFalse(config.is_record(f"docs/{name}.md", docs))
        self.assertTrue(config.is_record("docs/archive/plans/old.md", docs))
        self.assertTrue(config.is_record("docs/archive/plans/old.md", None))
        self.assertFalse(config.is_record("docs/plans/x.md", None))
        self.assertFalse(config.is_record("docs/h.md", docs))


class IndexReader(unittest.TestCase):
    def test_no_index_is_none(self) -> None:
        with support.git_repo() as repo:
            self.assertIsNone(config.read_index(repo, None))
            support.commit(repo, {"README.md": "x\n"}, "first")
            self.assertIsNone(config.read_index(repo, "HEAD"))

    def test_the_docs_object_is_returned(self) -> None:
        text = json.dumps({"schema_version": 3, "docs": index(docs__a_md="plan")})
        with support.git_repo() as repo:
            put(repo, {"docs/.doc-index.json": text})
            self.assertEqual(config.read_index(repo, None), index(docs__a_md="plan"))

    def test_the_index_is_read_from_a_revision_when_one_is_given(self) -> None:
        with support.git_repo() as repo:
            first = support.commit(
                repo, {"docs/.doc-index.json": json.dumps({"docs": index(docs__a_md="plan")})}, "1")
            support.commit(
                repo, {"docs/.doc-index.json": json.dumps({"docs": index(docs__a_md="guide")})}, "2")

            self.assertEqual(config.read_index(repo, first), index(docs__a_md="plan"))
            self.assertEqual(config.read_index(repo, None), index(docs__a_md="guide"))

    def test_an_index_without_a_docs_object_is_none(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"docs/.doc-index.json": "{}"})
            self.assertIsNone(config.read_index(repo, None))

    def test_an_unreadable_index_names_the_file(self) -> None:
        cases = {"not json": "docs/.doc-index.json", "[]": "docs/.doc-index.json",
                 '{"docs": []}': "docs"}
        for text, expected in cases.items():
            with self.subTest(text=text), support.git_repo() as repo:
                put(repo, {"docs/.doc-index.json": text})
                with self.assertRaises(config.Malformed) as caught:
                    config.read_index(repo, None)
                self.assertIn("docs/.doc-index.json", str(caught.exception))
                self.assertIn(expected, str(caught.exception))


class Ledger(unittest.TestCase):
    def test_ledger_ids_become_code_patterns(self) -> None:
        with support.git_repo() as repo:
            put(repo, ledgers("orbit", "dock"))

            codes = config.load(repo).codes

        self.assertEqual(markdown.bare_codes("see orbit-14", codes), ["orbit-14"])
        self.assertEqual(markdown.bare_codes("see dock-2 and orbit-30", codes),
                         ["dock-2", "orbit-30"])
        self.assertEqual(len(codes.patterns), 5)

    def test_only_the_registered_names_followed_by_a_number_are_codes(self) -> None:
        with support.git_repo() as repo:
            put(repo, ledgers("orbit"))

            codes = config.load(repo).codes

        cases = {"see orbit-0": [], "see orbit-014x": [], "see orbit": [],
                 "see launch-14": [], "see xorbit-14": [], "see orbit-14x": [],
                 "see orbit-14.": ["orbit-14"], "see orbit-140": ["orbit-140"]}
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(markdown.bare_codes(text, codes), expected)

    def test_a_glossed_ledger_key_is_not_bare(self) -> None:
        with support.git_repo() as repo:
            put(repo, ledgers("orbit"))

            codes = config.load(repo).codes

        self.assertEqual(markdown.bare_codes("the leak in the fuel line (orbit-14) stays", codes),
                         [])

    def test_without_the_ledger_a_name_and_number_is_no_code(self) -> None:
        with support.git_repo() as repo:
            codes = config.load(repo).codes

        self.assertEqual(markdown.bare_codes("see orbit-14", codes), [])

    def test_a_ledger_without_a_registry_adds_nothing(self) -> None:
        with support.git_repo() as repo:
            put(repo, {LEDGER_CONFIG: "{}"})

            codes = config.load(repo).codes

        self.assertEqual(len(codes.patterns), 4)

    def test_a_registry_without_ledgers_adds_nothing(self) -> None:
        with support.git_repo() as repo:
            put(repo, {LEDGER_CONFIG: "{}", REGISTRY: json.dumps({"schema": "ledger-registry/1"})})

            self.assertEqual(len(config.load(repo).codes.patterns), 4)

    def test_a_registry_is_ignored_while_the_ledger_is_switched_off(self) -> None:
        with support.git_repo() as repo:
            put(repo, {REGISTRY: ledgers("orbit")[REGISTRY]})

            self.assertEqual(len(config.load(repo).codes.patterns), 4)

    def test_the_ledger_is_read_from_a_revision_when_one_is_given(self) -> None:
        with support.git_repo() as repo:
            before = support.commit(repo, {"README.md": "x\n"}, "first")
            after = support.commit(repo, ledgers("orbit"), "ledger")

            self.assertEqual(len(config.load(repo, before).codes.patterns), 4)
            self.assertEqual(len(config.load(repo, after).codes.patterns), 5)

    def test_the_items_folder_is_terse(self) -> None:
        settings = {"items": {"globs": ["docs/work/*.md"]}}
        with support.git_repo() as repo:
            put(repo, {LEDGER_CONFIG: json.dumps(settings)})

            loaded = config.load(repo)

        self.assertEqual(config.register_for("docs/work/2026-01-01-leak.md", loaded, None),
                         "terse")
        self.assertEqual(config.register_for("docs/guides/start.md", loaded, None), "full")
        self.assertEqual(config.register_for("docs/issues/x.md", loaded, None), "terse")

    def test_item_globs_of_each_shape(self) -> None:
        cases = {
            "docs/work/**/*.md": ("docs/work/a/b/leak.md", "terse"),
            "tracker/{open,done}/*.md": ("tracker/open/leak.md", None),
            "tracker/*.md": ("tracker/leak.md", "terse"),
            "tracker/leak.md": ("tracker/leak.md", "terse"),
            "docs/w*rk/*.md": ("docs/work/leak.md", "full"),
            "*.md": ("README.md", None),
            "**/leak-*.md": ("docs/leak-1.md", "full"),
        }
        for glob, (path, expected) in cases.items():
            with self.subTest(glob=glob), support.git_repo() as repo:
                put(repo, {LEDGER_CONFIG: json.dumps({"items": {"globs": [glob]}})})

                self.assertEqual(config.register_for(path, config.load(repo), None), expected)

    def test_an_items_rule_does_not_reach_files_the_glob_names_by_extension_only(self) -> None:
        with support.git_repo() as repo:
            put(repo, {LEDGER_CONFIG: json.dumps({"items": {"globs": ["tracker/*.md"]}})})

            loaded = config.load(repo)

        self.assertIsNone(config.register_for("tracker/leak.txt", loaded, None))

    def test_a_project_path_rule_wins_over_the_items_rule(self) -> None:
        settings = {"registers": {"paths": [{"prefix": "docs/work/", "register": "full"}]}}
        with support.git_repo() as repo:
            put(repo, {LEDGER_CONFIG: json.dumps({"items": {"globs": ["docs/work/*.md"]}}),
                       **project(settings)})

            loaded = config.load(repo)

        self.assertEqual(config.register_for("docs/work/x.md", loaded, None), "full")

    def test_items_globs_that_are_not_a_list_of_strings_are_ignored(self) -> None:
        for globs in ("docs/work/*.md", None, 3, [3, None, ""], {"a": "b"}):
            with self.subTest(globs=globs), support.git_repo() as repo:
                put(repo, {LEDGER_CONFIG: json.dumps({"items": {"globs": globs}})})

                loaded = config.load(repo)

                self.assertEqual(config.register_for("docs/work/x.md", loaded, None), "full")

    def test_a_malformed_ledger_file_names_the_file_and_the_key(self) -> None:
        cases = [
            ({LEDGER_CONFIG: "{oops"}, LEDGER_CONFIG, "JSON"),
            ({LEDGER_CONFIG: "[]"}, LEDGER_CONFIG, "object"),
            ({LEDGER_CONFIG: "{}", REGISTRY: "{oops"}, REGISTRY, "JSON"),
            ({LEDGER_CONFIG: "{}", REGISTRY: "[]"}, REGISTRY, "object"),
            ({LEDGER_CONFIG: "{}", REGISTRY: '{"ledgers": {}}'}, REGISTRY, "ledgers"),
            ({LEDGER_CONFIG: "{}", REGISTRY: '{"ledgers": [{"id": 3}]}'}, REGISTRY,
             "ledgers[0].id"),
            ({LEDGER_CONFIG: "{}", REGISTRY: '{"ledgers": ["orbit"]}'}, REGISTRY, "ledgers[0]"),
        ]
        for files, name, key in cases:
            with self.subTest(files=files), support.git_repo() as repo:
                put(repo, files)
                with self.assertRaises(config.Malformed) as caught:
                    config.load(repo)
                self.assertIn(name, str(caught.exception))
                self.assertIn(key, str(caught.exception))


class MalformedConfig(unittest.TestCase):
    def load_text(self, text: str | bytes) -> None:
        with support.git_repo() as repo:
            (repo / "docs" / "writing").mkdir(parents=True)
            data = text if isinstance(text, bytes) else text.encode("utf-8")
            (repo / CONFIG).write_bytes(data)
            config.load(repo)

    def test_malformed_config_names_the_key(self) -> None:
        cases = [
            ("bad json", "{not json", "JSON"),
            ("an unknown top-level key", '{"colour": true}', "colour"),
            ("an uncompilable pattern", '{"codes": {"patterns": ["ok", "(unclosed"]}}',
             "codes.patterns[1]"),
            ("an unknown nested key", '{"codes": {"patern": []}}', "codes.patern"),
            ("an unknown register key", '{"registers": {"doc_type": {}}}', "registers.doc_type"),
            ("an unknown limit key", '{"limits": {"full": {"words": 3}}}', "limits.full.words"),
            ("an unknown register in limits", '{"limits": {"loose": {"sentence": 3}}}',
             "limits.loose"),
            ("an unknown path rule key", '{"registers": {"paths": [{"folder": "x/"}]}}',
             "registers.paths[0].folder"),
            ("a path rule without a register", '{"registers": {"paths": [{"prefix": "x/"}]}}',
             "registers.paths[0].register"),
            ("a path rule with a wrong register",
             '{"registers": {"paths": [{"prefix": "x/", "register": "loud"}]}}',
             "registers.paths[0].register"),
            ("a wrong register for a doc type", '{"registers": {"doc_types": {"runbook": "loud"}}}',
             "registers.doc_types.runbook"),
            ("a null register for a doc type", '{"registers": {"doc_types": {"runbook": null}}}',
             "registers.doc_types.runbook"),
            ("a string for a limit", '{"limits": {"full": {"sentence": "forty"}}}',
             "limits.full.sentence"),
            ("a boolean for a limit", '{"limits": {"full": {"sentence": true}}}',
             "limits.full.sentence"),
            ("a zero limit", '{"limits": {"full": {"item": 0}}}', "limits.full.item"),
            ("a null sentence limit", '{"limits": {"full": {"sentence": null}}}',
             "limits.full.sentence"),
            ("a number for enabled", '{"enabled": 1}', "enabled"),
            ("a string for the patterns", '{"codes": {"patterns": "x"}}', "codes.patterns"),
            ("a number among the allowed words", '{"codes": {"allowed": ["P0", 3]}}',
             "codes.allowed[1]"),
            ("a two-character gloss", '{"codes": {"gloss_chars": ["ab"]}}',
             "codes.gloss_chars[0]"),
            ("an empty skipped prefix", '{"skip_prefixes": [""]}', "skip_prefixes[0]"),
            ("an empty skipped block header", '{"skip_blocks": ["Steps:", ""]}',
             "skip_blocks[1]"),
            ("a number among the skipped block headers", '{"skip_blocks": [3]}',
             "skip_blocks[0]"),
            ("a string for the skipped block headers", '{"skip_blocks": "Steps:"}',
             "skip_blocks"),
            ("a top level that is a list", "[]", "object"),
            ("a top level that is null", "null", "object"),
        ]
        for name, text, key in cases:
            with self.subTest(name):
                with self.assertRaises(config.Malformed) as caught:
                    self.load_text(text)
                self.assertIn(CONFIG, str(caught.exception))
                self.assertIn(key, str(caught.exception))

    def test_a_pattern_that_does_not_compile_says_why(self) -> None:
        with self.assertRaises(config.Malformed) as caught:
            self.load_text('{"codes": {"patterns": ["a(b"]}}')

        self.assertRegex(str(caught.exception), r"(?i)missing \)|unterminated|unbalanced")

    def test_a_file_that_is_not_utf8_is_malformed_not_a_traceback(self) -> None:
        with self.assertRaises(config.Malformed) as caught:
            self.load_text(b'{"skip_prefixes": ["\xff"]}')

        self.assertIn(CONFIG, str(caught.exception))
        self.assertIn("UTF-8", str(caught.exception))

    def test_a_malformed_file_at_a_revision_names_the_revision(self) -> None:
        with support.git_repo() as repo:
            rev = support.commit(repo, {CONFIG: '{"colour": 1}'}, "bad")

            with self.assertRaises(config.Malformed) as caught:
                config.load(repo, rev)

        self.assertIn(CONFIG, str(caught.exception))
        self.assertIn("colour", str(caught.exception))
        self.assertIn(rev, str(caught.exception))

    def test_a_directory_where_the_file_belongs_is_malformed(self) -> None:
        with support.git_repo() as repo:
            (repo / CONFIG).mkdir(parents=True)

            with self.assertRaises(config.Malformed) as caught:
                config.load(repo)

        self.assertIn(CONFIG, str(caught.exception))

    def test_malformed_is_a_value_error(self) -> None:
        self.assertTrue(issubclass(config.Malformed, ValueError))


class Shapes(unittest.TestCase):
    def test_the_named_tuples_have_the_documented_fields(self) -> None:
        self.assertEqual(config.Config._fields, ("enabled", "codes", "limits", "skip_prefixes",
                                                 "skip_blocks", "doc_types", "paths"))
        self.assertEqual(config.Limits._fields, ("sentence", "item", "item_sentences"))
        self.assertEqual(config.PathRule._fields, ("prefix", "suffix", "register"))
        self.assertFalse(hasattr(config, "COUNTING_VERSION"))


if __name__ == "__main__":
    unittest.main()
