defmodule Foxbus.PortsTest do
  use ExUnit.Case, async: true
  alias Foxbus.Ports.Provider

  describe "Provider.all/0" do
    test "includes carousel" do
      assert Foxbus.Adapters.Sources.CarouselProvider in Provider.all()
    end
  end

  describe "Provider.resolve/1" do
    test "finds a known provider's module by id" do
      assert Provider.resolve(:carousel) == Foxbus.Adapters.Sources.CarouselProvider
    end

    test "raises on an unknown provider id" do
      assert_raise ArgumentError, ~r/unknown foxbus provider/, fn ->
        Provider.resolve(:not_a_real_provider)
      end
    end
  end
end
