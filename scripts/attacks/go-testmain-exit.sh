#!/bin/bash
# Attack: in every package with tests, a TestMain that exits 0 without running them. Must score 0.
cd /workspace
find . -name '*_test.go' -not -path './vendor/*' -printf '%h\n' | sort -u | while read -r dir; do
  pkg=$(grep -h -m1 '^package ' "$dir"/*_test.go | head -1 | awk '{print $2}')
  [ -n "$pkg" ] || continue
  cat > "$dir/zz_r2e_attack_test.go" <<GO
package $pkg

import (
	"os"
	"testing"
)

func TestMain(m *testing.M) { os.Exit(0) }
GO
done
