defmodule Foxbus.Adapters.Sources.CarouselCacheTest do
  use ExUnit.Case, async: false
  alias Foxbus.Adapters.Sources.CarouselCache

  setup do
    start_supervised!(CarouselCache)
    :ok
  end

  test "a second fetch for the same URL within the TTL reuses the first result" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    fun = fn -> Agent.update(calls, &(&1 + 1)) end

    assert CarouselCache.fetch("http://x", fn ->
             fun.()
             {:ok, "first"}
           end) == {:ok, "first"}

    assert CarouselCache.fetch("http://x", fn ->
             fun.()
             {:ok, "second"}
           end) == {:ok, "first"}

    assert Agent.get(calls, & &1) == 1
  end

  test "an error isn't cached -- the next fetch for the same URL tries again" do
    assert CarouselCache.fetch("http://y", fn -> {:error, :boom} end) == {:error, :boom}
    assert CarouselCache.fetch("http://y", fn -> {:ok, "recovered"} end) == {:ok, "recovered"}
  end

  test "different URLs are cached independently" do
    assert CarouselCache.fetch("http://a", fn -> {:ok, "a"} end) == {:ok, "a"}
    assert CarouselCache.fetch("http://b", fn -> {:ok, "b"} end) == {:ok, "b"}
  end
end
