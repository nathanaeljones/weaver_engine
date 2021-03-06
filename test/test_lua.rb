
class CheckLuaSyntax < MiniTest::Test



  def test_sandbox_syntax
    test_syntax('../lib/lua_engine/sandbox.lua')
  end

  def test_pluto_persist_uids_are_not_picky
    s = Rufus::Lua::State.new()
    assert_equal(1.0, s.eval(%{
      require "pluto"

      pp = {["a"]=1}
      up = {[1]="a"}
      data = {c="a",d=1}
      t = pluto.unpersist(up,pluto.persist(pp, data))
      return t.d
      }))
    s.close
  end

private
  def test_syntax(path)
    source = File.read(File.expand_path(path, File.dirname(__FILE__)))
    s = Rufus::Lua::State.new()
    data = WeaverEngine::MemDataAdapter.new('tester','master',{})
    data.add_to_state(s,"host.")
    WeaverEngine::MemDisplayAdapter.new(data).add_to_state(s,"host.")
    s.eval(source)
    s.close
  end
end