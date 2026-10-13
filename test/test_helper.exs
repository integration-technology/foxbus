# NestGen2.Storage.dir/1 (called even by get/3, as a read) creates its
# directory if missing — the real default, /media/scratch/.nest_gen2_sdk/data,
# only exists on the Nest itself. Redirect it here, once, for every test, not
# just the ones that deliberately exercise Storage (Foxbus.Config and
# Foxbus.ScreenPower both go through it now, so anything touching either one
# — directly or not, e.g. via Foxbus.Arrivals — would otherwise try to create
# that path on whatever machine runs the tests).
test_storage_dir = Path.join(System.tmp_dir!(), "foxbus_test_storage_#{System.pid()}")
Application.put_env(:nest_gen2, :storage_dir, test_storage_dir)
System.at_exit(fn _ -> File.rm_rf(test_storage_dir) end)

ExUnit.start()
