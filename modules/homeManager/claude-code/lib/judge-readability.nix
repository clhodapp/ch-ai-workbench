# SPDX-License-Identifier: MIT
# Seed dimensions for ch-ai-workbench.claude-code.judge.dimensions: how
# much work a reply makes for a developer who has not seen the work.
# Scores never push back: the context hook hands each one to the model
# with the next prompt, as the expected position on the scale and the
# most likely level, beside `rule`, the peer-programmer style's aim.
# assumed-context leaves aside what the subject requires, so a reply
# about this codebase is not marked up for using its names.
let
  replies = [
    "reply"
    "progress"
  ];
in
{
  assumed-context = {
    type = "score";
    instructions = "Leaving aside what the subject itself requires (a question about this codebase needs its names), how much does the message assume the reader already knows: names, decisions, earlier messages, or shorthand that a developer who knows the subject but did not see the work would have to look up or guess at?";
    levels = [
      "nothing beyond the subject: every name and reference is explained or standard for the topic"
      "a little: one or two names or references that such a reader would have to look up"
      "a lot: many names, decisions, or earlier messages left unexplained"
      "it reads as a note to someone who took part in the work: references from the chat or task carry the meaning"
    ];
    rule = "write for a programmer who knows the subject but has not seen the work: give each name a few words on what it is, and restate what an earlier message decided";
    targets = replies;
  };

  information-density = {
    type = "score";
    instructions = "How much does each sentence of the message carry, whoever reads it?";
    levels = [
      "sparse: filler, repetition, or points restated"
      "even: about one point per sentence"
      "dense: several facts per sentence"
      "packed: nearly every clause carries a fact the reader has to stop and take in"
    ];
    rule = "one point per sentence, with the words it needs; cut filler and restatement";
    targets = replies;
  };

  generic-concept-words = {
    instructions = "Does the message use a generic noun as if it were the name of a specific concept, without saying what it is, such as \"the fold\", \"the gate\", \"the surface\", \"the shape\", or \"the path\", where the reader cannot tell which function, file, check, or mechanism is meant?";
    criteria.true = "A generic noun stands in for a specific thing the message never names.";
    criteria.false = "Every concept is named by what it is, or a generic noun is defined where it first appears.";
    rule = "name the actual thing (the function, the file, the check) instead of a generic noun that stands for it";
    targets = replies;
  };

  unexplained-references = {
    instructions = "Does the message refer to a file, option, command, pull request, decision, or earlier message without the few words a reader who did not see the work needs to know what it is, such as \"the second approach\", \"per the earlier fix\", or a bare option name whose role is never said?";
    criteria.true = "At least one reference only makes sense to someone who remembers the work or the earlier conversation.";
    criteria.false = "Each reference comes with its path or name and a few words on what it is or does, or needs none for this reader.";
    rule = "give each file, option, module, or command its path or name and a few words on what it does at first mention, and restate what an earlier message decided instead of pointing at it";
    targets = replies;
  };
}
