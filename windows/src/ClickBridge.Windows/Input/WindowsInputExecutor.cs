using System.Runtime.InteropServices;
using ClickBridge.Core;
using ClickBridge.Core.Actions;

namespace ClickBridge.Windows.Input;

/// <summary>
/// Port of mac/ClickBridgeMac/MacInputExecutor.swift. CGEvent posts a mouse
/// event at an explicit cursor location and marks it with
/// mouseEventClickState = 1 so macOS never folds repeated posts into a
/// double/triple click. Win32's SendInput has no equivalent per-event click
/// count: it always posts relative to the *current* cursor position when
/// dx/dy are 0 and MOUSEEVENTF_ABSOLUTE is not set, but whether the
/// receiving app's own click-counting treats three rapid down/up pairs as
/// three single clicks or as escalating multi-clicks is up to that app —
/// there is no OS-level flag to force "always a single click" the way
/// CGEvent's mouseEventClickState does. If a target app is folding the
/// three posts into a double/triple-click gesture, raise clickGapMs.
/// </summary>
public sealed class WindowsInputExecutor : IInputPosting
{
    private const uint InputMouse = 0;
    private const uint MouseEventFLeftDown = 0x0002;
    private const uint MouseEventFLeftUp = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    // Explicit union layout matching the native INPUT struct. Offset 8 for
    // the payload is correct only on x64 (a 4-byte Type padded to 8-byte
    // alignment because MouseInput holds a pointer-sized field) — this app
    // only publishes win-x64, see ClickBridge.Windows.csproj.
    [StructLayout(LayoutKind.Explicit)]
    private struct Input
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public MouseInput Mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint numberOfInputs, Input[] inputs, int structSize);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    private readonly int _clickGapMs;
    private readonly object _gate = new();
    private int _mouseDownPostCount;
    private int _mouseUpPostCount;

    public WindowsInputExecutor(int clickGapMs = Constants.ClickGapMs)
    {
        _clickGapMs = clickGapMs;
    }

    public InputPostOutcome PostLeftClickAtCurrentCursor()
    {
        if (!GetCursorPos(out _))
        {
            return new InputPostOutcome.CreationFailed();
        }

        var mouseDownUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        for (var i = 0; i < Constants.ClickRepetitions; i++)
        {
            if (!PostSingleEvent(MouseEventFLeftDown))
            {
                return new InputPostOutcome.CreationFailed();
            }
            lock (_gate) { _mouseDownPostCount++; }

            if (_clickGapMs > 0)
            {
                Thread.Sleep(_clickGapMs);
            }

            if (!PostSingleEvent(MouseEventFLeftUp))
            {
                return new InputPostOutcome.CreationFailed();
            }
            lock (_gate) { _mouseUpPostCount++; }
        }
        return new InputPostOutcome.Posted(mouseDownUnixMs);
    }

    public InputPostCounts DiagnosticPostCounts()
    {
        lock (_gate)
        {
            return new InputPostCounts(_mouseDownPostCount, _mouseUpPostCount);
        }
    }

    private static bool PostSingleEvent(uint flags)
    {
        var input = new Input { Type = InputMouse, Mi = new MouseInput { Flags = flags } };
        return SendInput(1, [input], Marshal.SizeOf<Input>()) == 1;
    }
}
