# SPDX-License-Identifier: MIT
#
# `{ lib, config, name }` to the entry of `caisson.exports.configurations`
# for the nemacs configuration called `name` that is declared inside the
# home-manager configuration `config`, or null when there is none. The
# entry holds the editor: `manifest.outputs.package` and
# `manifest.outputs.profile`, and the evaluated nemacs configuration in
# `manifest.value.config`.
#
# The childless evaluation of a home-manager configuration, which a
# nemacs configuration inside it reads, leaves out the configurations
# declared inside it, so the result is null there.
{
  lib,
  config,
  name,
}:
lib.findFirst (
  entry: entry.manifest.outputs.profile.kind == "nemacs" && entry.manifest.outputs.profile.name == name
) null (lib.caisson.integrations.profilesActivatedBy lib.caisson.evalManifest config.caisson.exports.configurations)
