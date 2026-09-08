# SPDX-License-Identifier: MIT
# Seed table for ch-ai-workbench.claude-code.ticChecks: the
# peer-programmer style's banned phrasings that a regex can catch
# with few false positives.  Patterns are GNU grep EREs matched
# case-insensitively against the finished message with code fences
# and backtick spans removed; the rule is the one-line reminder the
# model gets back.  Left out on purpose: "never", "grows", "seam",
# and "rides", which have too many ordinary uses for a pattern.
{
  # The ownership handoff: a possessive left dangling at the end of a
  # clause ("two steps are yours", "the merge is the owner's", "the
  # rest is mine", "the choice is my own").  A noun possessive is
  # elliptical when punctuation or the end of the line follows it
  # rather than a noun, so "the owner's act" does not match; the word
  # before the apostrophe must not itself open with one, so a
  # shell-quoted 'plural' passes; straight and curly apostrophes both
  # count.  "my own" follows the same punctuation rule.  The
  # possessive pronouns (yours, mine, ours, theirs) are elliptical
  # wherever they stand ("yours governs"), so they match anywhere.
  elliptical-possessive = {
    pattern = "(^|[^'’[:alnum:]])([[:alnum:]][[:alnum:]_-]*('s|’s|s'|s’)|my own)[[:space:]]*([[:punct:]]|”|$)|\\b(yours|mine|ours|theirs)\\b";
    rule = "no elliptical possessive (\"X is yours\", \"X is the owner's\", \"is mine\", \"is my own\"); a handoff names the next action and who does it in a plain sentence, not the owner";
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
