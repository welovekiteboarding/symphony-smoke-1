defmodule SymphonySmoke1Test do
  use ExUnit.Case

  test "hello/0 returns :world" do
    assert SymphonySmoke1.hello() == :world
  end

  test "graph_smoke_ready?/0 returns true" do
    assert SymphonySmoke1.graph_smoke_ready?() == true
  end
end
