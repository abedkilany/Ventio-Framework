using System.Text.Json;

namespace Ventio.HostSetupBroker;

internal static partial class NativeHostInstallation
{
    // The old Owner candidate hashed its executable/SQL closure but omitted
    // PostgreSQL libraries and share files from verifiedFiles. Fill only the
    // exact official 16.15-5 runtime, never arbitrary installed files.
    private static readonly Lazy<IReadOnlyDictionary<string, PayloadMember>> LegacyRuntimeInventory = new(ReadLegacyRuntimeInventory);
    internal static IReadOnlyDictionary<string, PayloadMember> ReviewedLegacyRuntime => LegacyRuntimeInventory.Value;

    private static IReadOnlyDictionary<string, PayloadMember> ReadLegacyRuntimeInventory()
    {
        using var stream = typeof(NativeHostInstallation).Assembly.GetManifestResourceStream("Ventio.LegacyPostgres1615Inventory.json")
            ?? throw Failure("LEGACY_RUNTIME_INVENTORY_MISSING");
        using var document = JsonDocument.Parse(stream);
        var root = document.RootElement;
        if (root.GetProperty("formatVersion").GetInt32() != 1 || root.GetProperty("postgresVersion").GetString() != "16.15" ||
            root.GetProperty("archiveSha256").GetString() != "43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281")
            throw Failure("LEGACY_RUNTIME_INVENTORY_INVALID");
        var members = new Dictionary<string, PayloadMember>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in root.GetProperty("members").EnumerateObject())
        {
            var value = property.Value;
            var member = new PayloadMember(value.GetProperty("length").GetInt64(), value.GetProperty("sha256").GetString() ?? "");
            if (!SafeRelativePath(property.Name) || !property.Name.StartsWith("postgresql/", StringComparison.Ordinal) ||
                member.Length < 0 || !System.Text.RegularExpressions.Regex.IsMatch(member.Sha256, "^[0-9a-f]{64}$") ||
                !members.TryAdd(property.Name, member)) throw Failure("LEGACY_RUNTIME_INVENTORY_INVALID");
        }
        if (members.Count != 1639) throw Failure("LEGACY_RUNTIME_INVENTORY_INVALID");
        return members;
    }

    internal static bool IsReviewedCriticalOnlyLegacyManifest(JsonElement root)
    {
        if (!root.TryGetProperty("postgresVersion", out var version) || version.GetString() != "16.15" ||
            root.GetProperty("verifiedFiles").GetArrayLength() >= root.GetProperty("payloadFileCount").GetInt32()) return false;
        return root.GetProperty("verifiedFiles").EnumerateArray().Any(entry =>
            entry.GetProperty("path").GetString() == "migrations/037_extension_submitter_review.sql" &&
            entry.GetProperty("sha256").GetString() is
                "d17d39218a3aad2d84638a74d55bf1a17a691fc04559e5e1ff4d458afff9bdf3" or
                "72a8b19c3d9757ecfb91ed8a7a6c7dd73459b14ec0b460a150d88f36ee6d8102");
    }

    internal static void ExpandReviewedLegacyManifest(JsonElement root, IDictionary<string, PayloadMember> members)
    {
        if (!IsReviewedCriticalOnlyLegacyManifest(root)) throw Failure("PAYLOAD_MANIFEST_INVALID");
        foreach (var (path, member) in ReviewedLegacyRuntime)
        {
            if (members.TryGetValue(path, out var listed))
            {
                if (listed != member) throw Failure("LEGACY_RUNTIME_HASH_INVALID");
            }
            else members.Add(path, member);
        }
        if (members.Count != root.GetProperty("payloadFileCount").GetInt32()) throw Failure("PAYLOAD_MANIFEST_INVALID");
    }
}
