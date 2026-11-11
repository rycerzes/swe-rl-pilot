# Issue

**Title:** v0.168.0: Panic with hugo gen docshelper

## Description

```text
$ hugo gen docshelper
Generate docs data to docs/data
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x8 pc=0x1079e4e]

goroutine 1 [running]:
github.com/gohugoio/hugo/internal/warpc.(*Dispatchers).NewWepCodec(...)
	/home/jmooring/code/hugo/internal/warpc/warpc.go:844
github.com/gohugoio/hugo/resources/images.NewImageProcessor({0x4e52230, 0xba0ff1b6c00}, {0x4e52230, 0xba0ff1b6fc0}, 0x0, 0xba0ff8f5080)
	/home/jmooring/code/hugo/resources/images/image.go:148 +0x32e
github.com/gohugoio/hugo/resources.NewSpec(0xba0ff2a2fc0, 0x0, 0x0, 0xba0fefa6bd0, 0xba0fee337a0, {0x4e10d68, 0xba0ff138dc0}, {0x4e59480, 0xba0ff0b5ad0}, {0x4e10d88, ...}, ...)
	/home/jmooring/code/hugo/resources/resource_spec.go:69 +0x11c
github.com/gohugoio/hugo/deps.(*Deps).Init(0xba0fef34d20)
	/home/jmooring/code/hugo/deps/deps.go:266 +0x10c8
github.com/gohugoio/hugo/tpl/cast.init.0.func1()
	/home/jmooring/code/hugo/tpl/cast/docshelper.go:29 +0x90
github.com/gohugoio/hugo/docshelper.GetDocProvider()
	/home/jmooring/code/hugo/docshelper/docs.go:35 +0x77
github.com/gohugoio/hugo/commands.newGenCommand.func4.func1({0x0?, 0x0?}, 0x0?, 0xba0ff3aec60, {0x0?, 0x0?, 0x0?})
	/home/jmooring/code/hugo/commands/gen.go:234 +0x114
github.com/gohugoio/hugo/commands.(*simpleCommand).Run(0x0?, {0x4e4c040?, 0x5cd3f40?}, 0x0?, {0x5cd3f40?, 0xba0ff8bf928?, 0x0?})
	/home/jmooring/code/hugo/commands/commandeer.go:681 +0x3f
github.com/bep/simplecobra.(*Commandeer).compile.func1(0xba0ff478400?, {0x5cd3f40?, 0x4?, 0x253e087?})
	/home/jmooring/go/pkg/mod/github.com/bep/simplecobra@v0.7.0/simplecobra.go:113 +0x4c
github.com/spf13/cobra.(*Command).execute(0xba0ff458908, {0x5cd3f40, 0x0, 0x0})
	/home/jmooring/go/pkg/mod/github.com/spf13/cobra@v1.10.2/command.go:1015 +0xb3c
github.com/spf13/cobra.(*Command).ExecuteC(0xba0feca2c08)
	/home/jmooring/go/pkg/mod/github.com/spf13/cobra@v1.10.2/command.go:1148 +0x450
github.com/spf13/cobra.(*Command).ExecuteContextC(...)
	/home/jmooring/go/pkg/mod/github.com/spf13/cobra@v1.10.2/command.go:1080
github.com/bep/simplecobra.(*Exec).Execute(0xba0ff122478, {0x4e4c040?, 0x5cd3f40?}, {0xba0fecf2310?, 0x0?, 0x0?})
	/home/jmooring/go/pkg/mod/github.com/bep/simplecobra@v0.7.0/simplecobra.go:155 +0xce
github.com/gohugoio/hugo/commands.Execute({0xba0fecf2310, 0x2, 0x2})
	/home/jmooring/code/hugo/commands/commandeer.go:69 +0x2ec
main.main()
	/home/jmooring/code/hugo/main.go:28 +0x5a

```

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `00fe8db2ccfe` and running the modified tests.