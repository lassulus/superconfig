import asyncio
import socket
import unittest

import server
import sunray


class Frames(unittest.TestCase):
    def test_roundtrip(self):
        payloads = [(9, b""), (10, b"x"), (11, (bytes(range(256)) * 256)[:65535])]
        stream = b"".join(server.frame(o, d) for o, d in payloads)

        async def run():
            reader = asyncio.StreamReader()
            # deliver in odd-sized chunks so headers and payloads split
            for i in range(0, len(stream), 7):
                reader.feed_data(stream[i : i + 7])
            reader.feed_eof()
            got = []
            await server.read_frames(reader, lambda o, d: got.append((o, d)))
            return got

        self.assertEqual(asyncio.run(run()), payloads)


class Relay(unittest.TestCase):
    def test_udp_through_frames(self):
        """moonlight -> client Udp -> frames -> server Udp -> sunshine and back."""

        async def run():
            loop = asyncio.get_running_loop()
            # stand-in for Sunshine: echo every datagram, uppercased
            sunshine, _ = await loop.create_datagram_endpoint(
                lambda: Echo(), local_addr=("127.0.0.1", 0)
            )
            sun_port = sunshine.get_extra_info("sockname")[1]

            to_server = Pipe()
            to_client = Pipe()
            srv, _ = await loop.create_datagram_endpoint(
                lambda: server.Udp(9, to_client), remote_addr=("127.0.0.1", sun_port)
            )
            _, cli = await loop.create_datagram_endpoint(
                lambda: sunray.Udp(9, to_server), local_addr=("127.0.0.2", 0)
            )
            cli_port = cli.transport.get_extra_info("sockname")[1]
            relays = [
                asyncio.create_task(server.read_frames(to_server.reader, lambda o, d: srv.sendto(d))),
                asyncio.create_task(server.read_frames(to_client.reader, lambda o, d: cli.send(d))),
            ]

            moonlight = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            moonlight.setblocking(False)
            moonlight.sendto(b"ping", ("127.0.0.2", cli_port))
            reply = await asyncio.wait_for(loop.sock_recv(moonlight, 100), 5)
            for r in relays:
                r.cancel()
            for t in (sunshine, srv, cli.transport, moonlight):
                t.close()
            return reply

        self.assertEqual(asyncio.run(run()), b"PING")


class Echo(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.transport.sendto(data.upper(), addr)


class Pipe:
    """A writer whose bytes come out of .reader, like ssh's stdio."""

    def __init__(self):
        self.reader = asyncio.StreamReader()

    def write(self, data):
        self.reader.feed_data(data)


class Loopback(unittest.TestCase):
    def test_stable_and_in_range(self):
        a = sunray.loopback("ignavia")
        self.assertEqual(a, sunray.loopback("ignavia"))
        self.assertNotEqual(a, sunray.loopback("atlas"))
        octets = [int(x) for x in a.split(".")]
        self.assertEqual(octets[0], 127)
        self.assertTrue(1 <= octets[3] <= 254)


if __name__ == "__main__":
    unittest.main()
