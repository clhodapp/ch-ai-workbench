# SPDX-License-Identifier: MIT
"""Unit tests for the in-place three-way merge, on JSON dicts and on
tomlkit documents."""

import unittest

import tomlkit

from agent_config.merge import merge, plain


class JsonMergeTest(unittest.TestCase):
    def test_first_apply_into_empty(self):
        doc = {}
        report = merge(doc, {}, {"model": "opus", "env": {"A": "1"}})
        self.assertEqual(doc, {"model": "opus", "env": {"A": "1"}})
        self.assertEqual(report.lines("t"), [])

    def test_foreign_keys_pass_through_inside_written_tables(self):
        doc = {"theme": "dark", "env": {"MINE": "x", "A": "0"}}
        merge(doc, {"env": {"A": "0"}}, {"env": {"A": "1"}})
        self.assertEqual(doc, {"theme": "dark", "env": {"MINE": "x", "A": "1"}})

    def test_dropped_scalar_is_removed_when_untouched(self):
        doc = {"model": "opus", "other": 1}
        merge(doc, {"model": "opus"}, {})
        self.assertEqual(doc, {"other": 1})

    def test_dropped_scalar_changed_by_hand_is_kept_and_reported(self):
        doc = {"model": "sonnet"}
        report = merge(doc, {"model": "opus"}, {})
        self.assertEqual(doc, {"model": "sonnet"})
        self.assertEqual(report.preserved, [("model", "sonnet")])

    def test_declared_scalar_overrides_hand_edit_and_reports(self):
        doc = {"model": "sonnet"}
        report = merge(doc, {"model": "opus"}, {"model": "fable"})
        self.assertEqual(doc, {"model": "fable"})
        self.assertEqual(report.overridden, [("model", "sonnet", "fable")])

    def test_runtime_change_of_undeclared_base_is_not_reported_when_same(self):
        doc = {"model": "fable"}
        report = merge(doc, {"model": "opus"}, {"model": "fable"})
        self.assertEqual(report.lines("t"), [])

    def test_list_keeps_adhoc_entries_after_declared(self):
        doc = {"deny": ["hand", "old"]}
        report = merge(doc, {"deny": ["old"]}, {"deny": ["new"]})
        self.assertEqual(doc, {"deny": ["new", "hand"]})
        self.assertEqual(report.adhoc, [("deny", ["hand"])])

    def test_list_emptied_is_removed(self):
        doc = {"deny": ["old"], "x": 1}
        merge(doc, {"deny": ["old"]}, {})
        self.assertEqual(doc, {"x": 1})

    def test_table_left_empty_is_pruned(self):
        doc = {"mcpServers": {"emacs": {"command": "e"}}}
        merge(doc, {"mcpServers": {"emacs": {"command": "e"}}}, {})
        self.assertEqual(doc, {})

    def test_table_with_foreign_keys_survives_removal(self):
        doc = {"mcpServers": {"emacs": {"command": "e"}, "mine": {"command": "m"}}}
        merge(doc, {"mcpServers": {"emacs": {"command": "e"}}}, {})
        self.assertEqual(doc, {"mcpServers": {"mine": {"command": "m"}}})

    def test_scalar_replaced_by_table(self):
        doc = {"sandbox": "on"}
        merge(doc, {}, {"sandbox": {"enabled": True}})
        self.assertEqual(doc, {"sandbox": {"enabled": True}})

    def test_idempotent(self):
        new = {"a": {"b": [1, 2], "c": "d"}}
        doc = {}
        merge(doc, {}, new)
        once = dict(doc)
        report = merge(doc, new, new)
        self.assertEqual(doc, once)
        self.assertEqual(report.lines("t"), [])


TOML_TEXT = """\
# chosen with /model
model = "gpt-5"  # trailing comment

[projects."/home/u/src"]
trust_level = "trusted"

[mcp_servers.mine]
command = "mine"
"""


class TomlMergeTest(unittest.TestCase):
    def test_comments_and_foreign_tables_survive(self):
        doc = tomlkit.parse(TOML_TEXT)
        merge(doc, {}, {"mcp_servers": {"emacs": {"command": "/p/bin/emacs-mcp-stdio"}}})
        text = tomlkit.dumps(doc)
        self.assertIn("# chosen with /model", text)
        self.assertIn("# trailing comment", text)
        self.assertIn('[projects."/home/u/src"]', text)
        self.assertEqual(
            plain(doc)["mcp_servers"],
            {"mine": {"command": "mine"}, "emacs": {"command": "/p/bin/emacs-mcp-stdio"}},
        )

    def test_unchanged_value_keeps_its_comment(self):
        doc = tomlkit.parse(TOML_TEXT)
        merge(doc, {"model": "gpt-5"}, {"model": "gpt-5"})
        self.assertEqual(tomlkit.dumps(doc), TOML_TEXT)

    def test_removal_from_toml(self):
        doc = tomlkit.parse(TOML_TEXT)
        merge(doc, {"mcp_servers": {"emacs": {"command": "e"}}}, {"mcp_servers": {"emacs": {"command": "e"}}})
        merge(doc, {"mcp_servers": {"emacs": {"command": "e"}}}, {})
        self.assertEqual(plain(doc)["mcp_servers"], {"mine": {"command": "mine"}})

    def test_new_nested_table_in_empty_document(self):
        doc = tomlkit.document()
        merge(doc, {}, {"sandbox_workspace_write": {"network_access": True, "writable_roots": ["/a"]}})
        self.assertEqual(
            tomlkit.parse(tomlkit.dumps(doc)).unwrap(),
            {"sandbox_workspace_write": {"network_access": True, "writable_roots": ["/a"]}},
        )


if __name__ == "__main__":
    unittest.main()
