# SPDX-License-Identifier: MIT
# Seed score dimension for ch-ai-workbench.claude-code.judge.dimensions:
# how much each sentence of a reply carries.  It never pushes back on its
# own: the context hook reports it with the next prompt, beside `rule`,
# and the reading-load check (judge.load) combines it with the length of
# the final message.
{
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
    targets = [
      "reply"
      "progress"
    ];
  };
}
