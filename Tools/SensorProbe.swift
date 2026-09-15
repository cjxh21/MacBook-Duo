import Foundation
import QuartzCore

@main
struct SensorProbe {
    @MainActor static func main() {
        let args=CommandLine.arguments
        let rate=Int(args.dropFirst().first ?? "30") ?? 30
        let sensor=LidAngleSensor(); sensor.start(); sensor.setRate(rate)
        let start=CACurrentMediaTime()
        var previous=0.0, count=0, times:[Double]=[]
        while CACurrentMediaTime()-start<60 {
            RunLoop.main.run(until:Date().addingTimeInterval(0.005))
            let s=sensor.snapshot
            if s.sample.time != previous { previous=s.sample.time;count += 1;times.append(s.sample.readDuration) }
        }
        sensor.shutdown()
        let result:[String:Any]=["duration":CACurrentMediaTime()-start,"rate":rate,"observedReads":count,
            "meanReadMs":times.isEmpty ? 0 : times.reduce(0,+)/Double(times.count)*1000,"note":"standalone sensor probe; does not measure capture/render or battery power"]
        let data=try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
    }
}
