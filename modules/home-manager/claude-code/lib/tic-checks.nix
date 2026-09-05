# SPDX-License-Identifier: MIT
# Seed table for ch-ai-workbench.claude-code.ticChecks: the
# peer-programmer style's banned phrasings that a regex can catch
# with few false positives.  Patterns are GNU grep EREs matched
# case-insensitively against the finished message with code fences
# and backtick spans removed; the rule is the one-line reminder the
# model gets back.  Left out on purpose: "never", "grows", "seam",
# and "rides", which have too many ordinary uses for a pattern.
{
  yours = {
    pattern = "\\byours\\b";
    rule = "a handoff names the next action, not the owner (\"X is yours\" is banned)";
  };
  em-dash = {
    pattern = "—";
    rule = "no em-dashes; use a comma, a colon, parentheses, or a separate sentence";
  };
  click = {
    pattern = "\\bclick(s|ed|ing)?\\b";
    rule = "name the reader's act (run, select, answer, confirm), not \"click\"";
  };
  arrow = {
    pattern = "→";
    rule = "write the sentence; no \"X → Y\" shorthand";
  };
  relationship-words = {
    pattern = "\\b(load-bearing|substrate|travels)\\b";
    rule = "say the actual relationship or what breaks, not \"load-bearing\", \"substrate\", or \"travels\"";
  };
  performed-enthusiasm = {
    pattern = "\\b(happy|glad) to\\b";
    rule = "no performed enthusiasm; make offers as plain conditionals";
  };
}
