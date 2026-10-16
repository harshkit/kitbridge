# TCP relay that records every byte between the test phone and the Mac, then checks no
# message content crossed the wire readable. Usage: sniff.py <listen-port> <mac-port> <out-file>
import socket, sys, threading
lp, mp, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", lp)); srv.listen(8)
cap = open(out, "ab")
def pipe(a, b):
    try:
        while d := a.recv(65536):
            cap.write(d); cap.flush(); b.sendall(d)
    except OSError: pass
    for s in (a, b):
        try: s.shutdown(socket.SHUT_RDWR)
        except OSError: pass
while True:
    c, _ = srv.accept(); m = socket.create_connection(("127.0.0.1", mp))
    threading.Thread(target=pipe, args=(c, m), daemon=True).start()
    threading.Thread(target=pipe, args=(m, c), daemon=True).start()
