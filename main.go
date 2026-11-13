package main

import (
	"embed"
	"os"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/api"
	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	var service api.Service = api.NewAWSService()
	if os.Getenv("ADBM_FIXTURES") == "1" {
		service = api.NewFixtureService()
	}

	if os.Getenv("ADBM_CLI") == "1" {
		runCLI(service)
		return
	}

	app := NewApp(service)

	err := wails.Run(&options.App{
		Title:  "AWS DB Backup Manager",
		Width:  1280,
		Height: 832,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 0, G: 0, B: 0, A: 0},
		OnStartup:        app.startup,
		Bind: []interface{}{
			app,
		},
		Mac: &mac.Options{
			TitleBar:             mac.TitleBarHiddenInset(),
			WebviewIsTransparent: true,
			WindowIsTranslucent:  true,
			About: &mac.AboutInfo{
				Title:   "AWS DB Backup Manager",
				Message: "Local, read-only-by-default RDS/Aurora backup and restore manager.\nNo delete, ever.",
			},
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
