using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;

namespace iToPC.Receiver;

internal static class UsbMuxClient
{
    private const int UsbMuxPort = 27015;
    private const uint ProtocolVersion = 1;
    private const uint PlistMessage = 8;
    private static int _nextTag;

    public static async Task<TcpClient> ConnectFirstUsbDeviceAsync(int devicePort, CancellationToken cancellationToken)
    {
        var device = await FindFirstUsbDeviceAsync(cancellationToken);
        var client = await ConnectToDaemonAsync(cancellationToken);

        try
        {
            var networkOrderPort = unchecked((ushort)IPAddress.HostToNetworkOrder(unchecked((short)devicePort)));
            var request = BuildRequest(
                "Connect",
                ("DeviceID", device.DeviceId),
                ("PortNumber", (int)networkOrderPort));
            await SendPacketAsync(client.GetStream(), request, cancellationToken);
            var response = await ReadPacketAsync(client.GetStream(), cancellationToken);
            var result = ReadInteger(response, "Number");
            if (result != 0)
            {
                throw new IOException(result switch
                {
                    2 => "USB接続中のiPhoneが切断されました。",
                    3 => "iPhoneアプリの配信ポートへ接続できません。先にiPhone側で［配信開始］を押してください。",
                    _ => $"Apple Mobile Deviceの接続に失敗しました (usbmux error {result})。"
                });
            }

            client.NoDelay = true;
            return client;
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    private static async Task<UsbDevice> FindFirstUsbDeviceAsync(CancellationToken cancellationToken)
    {
        using var client = await ConnectToDaemonAsync(cancellationToken);
        var request = BuildRequest("ListDevices");
        await SendPacketAsync(client.GetStream(), request, cancellationToken);
        var response = await ReadPacketAsync(client.GetStream(), cancellationToken);

        var document = ParseXmlPlist(response);
        var rootDictionary = document.Root?.Element("dict")
            ?? throw new IOException("Apple Mobile Deviceから不正な応答を受け取りました。");
        var listElement = FindValue(rootDictionary, "DeviceList");
        var deviceArray = listElement?.Name.LocalName == "array" ? listElement : null;
        if (deviceArray is null)
        {
            throw new IOException("USB接続中のiPhoneを検出できませんでした。端末のロックを解除し、このPCを信頼してください。");
        }

        var devices = new List<UsbDevice>();
        foreach (var deviceDictionary in deviceArray.Elements("dict"))
        {
            var idElement = FindValue(deviceDictionary, "DeviceID");
            if (idElement is null || !int.TryParse(idElement.Value, out var deviceId)) continue;

            var properties = FindValue(deviceDictionary, "Properties");
            var connectionType = properties?.Name.LocalName == "dict"
                ? FindValue(properties, "ConnectionType")?.Value
                : null;
            var serial = properties?.Name.LocalName == "dict"
                ? FindValue(properties, "SerialNumber")?.Value
                : null;
            devices.Add(new UsbDevice(deviceId, serial ?? "unknown", connectionType ?? "unknown"));
        }

        var usbDevice = devices.FirstOrDefault(device =>
            string.Equals(device.ConnectionType, "USB", StringComparison.OrdinalIgnoreCase));
        if (usbDevice is null)
        {
            throw new IOException("USB接続中のiPhoneを検出できませんでした。Apple DevicesまたはiTunesのドライバーを確認してください。");
        }
        return usbDevice;
    }

    private static async Task<TcpClient> ConnectToDaemonAsync(CancellationToken cancellationToken)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(IPAddress.Loopback, UsbMuxPort, cancellationToken);
            return client;
        }
        catch (Exception error)
        {
            client.Dispose();
            throw new IOException(
                "Apple Mobile Deviceサービスへ接続できません。Apple DevicesまたはiTunesをインストールし、サービスを起動してください。",
                error);
        }
    }

    private static async Task SendPacketAsync(NetworkStream stream, string plist, CancellationToken cancellationToken)
    {
        var payload = Encoding.UTF8.GetBytes(plist);
        var packet = new byte[16 + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(0, 4), (uint)packet.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4, 4), ProtocolVersion);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(8, 4), PlistMessage);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(12, 4), unchecked((uint)Interlocked.Increment(ref _nextTag)));
        payload.CopyTo(packet, 16);
        await stream.WriteAsync(packet, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static async Task<byte[]> ReadPacketAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var header = new byte[16];
        await ReadExactlyAsync(stream, header, cancellationToken);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0, 4));
        if (length < 16 || length > 4 * 1024 * 1024)
        {
            throw new IOException("Apple Mobile Deviceから不正なパケットを受信しました。");
        }

        var payload = new byte[length - 16];
        await ReadExactlyAsync(stream, payload, cancellationToken);
        return payload;
    }

    private static async Task ReadExactlyAsync(Stream stream, Memory<byte> destination, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var count = await stream.ReadAsync(destination[offset..], cancellationToken);
            if (count == 0) throw new EndOfStreamException("Apple Mobile Deviceとの接続が切断されました。");
            offset += count;
        }
    }

    private static string BuildRequest(string messageType, params (string Key, object Value)[] values)
    {
        var dictionary = new XElement("dict");
        AddValue(dictionary, "MessageType", messageType);
        AddValue(dictionary, "ClientVersionString", "iToPC 0.1");
        AddValue(dictionary, "ProgName", "iToPC Receiver");
        AddValue(dictionary, "kLibUSBMuxVersion", 3);
        foreach (var value in values) AddValue(dictionary, value.Key, value.Value);

        var document = new XDocument(
            new XDeclaration("1.0", "UTF-8", null),
            new XDocumentType(
                "plist",
                "-//Apple//DTD PLIST 1.0//EN",
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd",
                null),
            new XElement("plist", new XAttribute("version", "1.0"), dictionary));
        return document.ToString(SaveOptions.DisableFormatting);
    }

    private static void AddValue(XElement dictionary, string key, object value)
    {
        dictionary.Add(new XElement("key", key));
        dictionary.Add(value switch
        {
            int integer => new XElement("integer", integer),
            uint integer => new XElement("integer", integer),
            bool boolean => new XElement(boolean ? "true" : "false"),
            _ => new XElement("string", value.ToString())
        });
    }

    private static XDocument ParseXmlPlist(byte[] payload)
    {
        try
        {
            return XDocument.Parse(Encoding.UTF8.GetString(payload));
        }
        catch (Exception error)
        {
            throw new IOException("Apple Mobile Deviceの応答plistを解析できません。", error);
        }
    }

    private static int ReadInteger(byte[] payload, string key)
    {
        var document = ParseXmlPlist(payload);
        var dictionary = document.Root?.Element("dict")
            ?? throw new IOException("Apple Mobile Deviceから不正な応答を受け取りました。");
        var value = FindValue(dictionary, key)
            ?? throw new IOException($"Apple Mobile Deviceの応答に{key}がありません。");
        return int.TryParse(value.Value, out var number)
            ? number
            : throw new IOException($"Apple Mobile Deviceの{key}が不正です。");
    }

    private static XElement? FindValue(XElement dictionary, string key)
    {
        var elements = dictionary.Elements().ToList();
        for (var index = 0; index + 1 < elements.Count; index++)
        {
            if (elements[index].Name.LocalName == "key" && elements[index].Value == key)
            {
                return elements[index + 1];
            }
        }
        return null;
    }

    private sealed record UsbDevice(int DeviceId, string SerialNumber, string ConnectionType);
}
