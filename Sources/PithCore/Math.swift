#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func pithSin(_ x: Double) -> Double { sin(x) }
func pithCos(_ x: Double) -> Double { cos(x) }
func pithAtan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) }
func pithHypot(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }

func pithWrap0to2Pi(_ angle: Double) -> Double {
    let twoPi = 2 * Double.pi
    var value = angle.truncatingRemainder(dividingBy: twoPi)
    if value < 0 { value += twoPi }
    return value
}
