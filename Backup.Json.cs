using System;
using System.Collections;
using System.Globalization;
using System.IO;
using System.Management.Automation;

public static class BackupJsonWriter
{
    static void Text(TextWriter writer, string value)
    {
        writer.Write('"');
        foreach (char c in value) {
            switch (c) {
                case '"': writer.Write("\\\""); break;
                case '\\': writer.Write("\\\\"); break;
                case '\b': writer.Write("\\b"); break;
                case '\f': writer.Write("\\f"); break;
                case '\n': writer.Write("\\n"); break;
                case '\r': writer.Write("\\r"); break;
                case '\t': writer.Write("\\t"); break;
                default: if (c < 32) writer.Write("\\u" + ((int)c).ToString("x4")); else writer.Write(c); break;
            }
        }
        writer.Write('"');
    }
    public static void Write(TextWriter writer, object value) { Write(writer, value, 0); }
    static void Write(TextWriter writer, object value, int depth)
    {
        PSObject shell = value as PSObject;
        if (shell != null && !(shell.BaseObject is PSCustomObject)) value = shell.BaseObject;
        if (value == null || value is DBNull) { writer.Write("null"); return; }
        if (depth > 30) { Text(writer, PSObject.AsPSObject(value).ToString()); return; }
        if (value is string || value is char || value is Guid || value is Uri) { Text(writer, value.ToString()); return; }
        if (value is bool) { writer.Write((bool)value ? "true" : "false"); return; }
        if (value is DateTime) { Text(writer, ((DateTime)value).ToString("o", CultureInfo.InvariantCulture)); return; }
        if (value is DateTimeOffset) { Text(writer, ((DateTimeOffset)value).ToString("o", CultureInfo.InvariantCulture)); return; }
        Type type = value.GetType();
        if (type.IsEnum) { value = Convert.ChangeType(value, Enum.GetUnderlyingType(type), CultureInfo.InvariantCulture); type = value.GetType(); }
        TypeCode code = Type.GetTypeCode(type);
        if (code >= TypeCode.SByte && code <= TypeCode.Decimal) {
            string number = value is double ? ((double)value).ToString("R", CultureInfo.InvariantCulture) : value is float ? ((float)value).ToString("R", CultureInfo.InvariantCulture) : Convert.ToString(value, CultureInfo.InvariantCulture);
            if (number == "NaN" || number.EndsWith("Infinity", StringComparison.Ordinal)) Text(writer, number); else writer.Write(number);
            return;
        }
        IDictionary dictionary = value as IDictionary;
        bool first = true;
        if (dictionary != null) {
            writer.Write('{');
            foreach (DictionaryEntry entry in dictionary) {
                if (!(entry.Key is string)) throw new InvalidOperationException("backup_json_property_name_invalid");
                if (!first) writer.Write(','); first = false; Text(writer, (string)entry.Key); writer.Write(':'); Write(writer, entry.Value, depth + 1);
            }
            writer.Write('}'); return;
        }
        IEnumerable sequence = value as IEnumerable;
        if (sequence != null) {
            writer.Write('[');
            foreach (object item in sequence) { if (!first) writer.Write(','); first = false; Write(writer, item, depth + 1); }
            writer.Write(']'); return;
        }
        writer.Write('{');
        foreach (PSPropertyInfo property in (shell ?? PSObject.AsPSObject(value)).Properties) {
            if (!property.IsGettable) continue;
            if (!first) writer.Write(','); first = false; Text(writer, property.Name); writer.Write(':'); Write(writer, property.Value, depth + 1);
        }
        writer.Write('}');
    }
}
