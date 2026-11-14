// Exercise actual fragmented Unix socket packets, including the old overflow.
#include "socketreader.h"
#include <QCoreApplication>
#include <QDir>
#include <QTemporaryDir>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cassert>
#include <cstring>
#include <thread>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QTemporaryDir root;
    assert(root.isValid());
    QDir().mkpath(root.path() + "/var/run");
    qputenv("SENSORFW_SOCKET_PATH", root.path().toUtf8());
    const auto path = (root.path() + "/var/run/sensord.sock").toUtf8();
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    assert(size_t(path.size()) < sizeof(address.sun_path));
    std::strcpy(address.sun_path, path.constData());
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(listener >= 0);
    assert(bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    std::thread server([&] {
        int peer = accept(listener, nullptr, nullptr);
        assert(peer >= 0);
        int session = -1;
        assert(recv(peer, &session, sizeof(session), MSG_WAITALL) == sizeof(session));
        assert(session == 7);
        assert(send(peer, "xAB", 3, 0) == 3);
        usleep(50000);
        assert(send(peer, "CDEFGH", 6, 0) == 6);
        unsigned empty = 0;
        assert(send(peer, &empty, sizeof(empty), 0) == sizeof(empty));
        unsigned count = 1;
        TimedUnsigned sample(123, 42);
        assert(send(peer, &count, sizeof(count), 0) == sizeof(count));
        assert(send(peer, &sample, sizeof(sample), 0) == sizeof(sample));
        char end;
        recv(peer, &end, 1, 0);
        close(peer);
    });
    {
        SocketReader rejected;
        assert(!rejected.initiateConnection(-1));
        SocketReader reader;
        assert(reader.initiateConnection(7));
        struct { char data[4]; char guard[4]; } buffer{{}, {'!', '!', '!', '!'}};
        assert(reader.read(buffer.data, 4));
        assert(std::memcmp(buffer.data, "ABCD", 4) == 0);
        assert(std::memcmp(buffer.guard, "!!!!", 4) == 0);
        char next[4];
        assert(reader.read(next, 4));
        assert(std::memcmp(next, "EFGH", 4) == 0);
        QVector<TimedUnsigned> samples;
        assert(!reader.read(samples));
        samples.append(TimedUnsigned(1, 9));
        assert(reader.read(samples));
        assert(samples.size() == 2 && samples[0].value_ == 9 && samples[1].value_ == 42);
        reader.dropConnection();
    }
    server.join();
    close(listener);
}
