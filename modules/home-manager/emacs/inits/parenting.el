;; SPDX-License-Identifier: MIT
;; init parenting
(use-package parenting-parent
  :commands
  (parenting-spawn
   parenting-listen
   parenting-eval-expression))
(use-package parenting-child
  :commands
  (parenting-child-connect
   parenting-child-start))
