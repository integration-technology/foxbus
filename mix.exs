defmodule Foxbus.MixProject do
  use Mix.Project

  def project do
    [
      app: :foxbus,
      version: "0.2.0",
      # The Nest runs Elixir 1.17 on OTP 26: build with that toolchain
      # (source nest_gen2_sdk/platform/host_env.sh).
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      deps: [
        nest_gen2_dep(),
        {:floki, "~> 0.38"},
        # JSON decoding for the TfL/rail providers — OTP 26 (this project's
        # toolchain) predates the built-in :json module, added in OTP 27.
        {:jason, "~> 1.4"}
      ]
    ]
  end

  # The SDK from Hex, or a local path for co-development (set NEST_GEN2_PATH
  # when working on both repos at once). "~> 0.5.0", not "~> 0.5" — the
  # trailing .0 matters, since "~> 0.5" alone would also allow a breaking 0.6
  # before 1.0. 0.5.0 adds NestGen2.Power.set_deep_sleep/1, which
  # Foxbus.ScreenPower is now built on.
  defp nest_gen2_dep do
    case System.get_env("NEST_GEN2_PATH") do
      nil -> {:nest_gen2, "~> 0.5.0"}
      path -> {:nest_gen2, path: path}
    end
  end

  # Settings live here rather than in config/*.exs: on the Nest the app is
  # started from plain erl, which only sees the .app file's env.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Foxbus.Application, []},
      env: [
        # Placeholder stops — see the README's "Run foxbus on your own Nest"
        # for finding your own ATCO codes and pointing these at them (either
        # here, or at runtime without a rebuild or redeploy, via
        # Foxbus.Config / platform/storage.sh). Each stop names its own
        # provider (see Foxbus.Ports.Provider.all/0) and watched lines — a
        # shared stop can be served by more than one route; list them all
        # and they're interleaved by time.
        stops: [
          %{
            key: :towards_somewhere,
            provider: :carousel,
            stop_id: "000000000001",
            title: "To Somewhere",
            lines: ["104", "105"]
          },
          %{
            key: :towards_elsewhere,
            provider: :carousel,
            stop_id: "000000000002",
            title: "To Elsewhere",
            lines: ["104", "105"]
          }
        ],
        arrivals_sink: Foxbus.Adapters.Sinks.ScreensSink,
        disruptions_sink: Foxbus.Adapters.Sinks.ScreensSink,
        stop_closure_sink: Foxbus.Adapters.Sinks.ScreensSink,
        wifi_source: Foxbus.Adapters.Sources.NestGen2WifiSource,
        assets_dir: "/media/scratch/.nest_gen2_sdk/foxbus",
        # Pre-0.3.0 config file, only consulted once by
        # Foxbus.Config.migrate_from_file/0 to carry an existing install's
        # values into NestGen2.Storage. nil means "config.exs next to
        # assets_dir". The live route/stops now live in Storage — see
        # platform/storage.sh.
        config_path: nil,
        # Pre-0.3.0 screen-power file, same deal — see
        # Foxbus.ScreenPower.migrate_from_file/0. nil means "screen_power.exs
        # next to assets_dir".
        screen_power_path: nil,
        screen_step_degrees: 45
      ]
    ]
  end
end
