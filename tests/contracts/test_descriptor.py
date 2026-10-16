from tools.verify_descriptor import verify

def test_recovered_wire_and_editions():
    report = verify()
    assert report['rpc_count'] == 11
    assert report['message_count'] == 22
