import Foundation

/// Categories with a built-in *typical* lifespan, used only when you haven't
/// owned this item before and haven't set a custom period.
///
/// These are rough, commonly cited replacement cycles chosen for this app,
/// not measured statistics for South Africa. They are a starting guess and
/// are always editable.
enum BelongingCategory: String, CaseIterable, Identifiable, Codable {
    case phone, laptop, tablet, smartwatch, headphones, tv, gamingConsole, camera
    case fridge, washingMachine, dishwasher, stove, microwave, kettle, vacuum
    case mattress, furniture, car, tyres, carBattery, bicycle
    case glasses, shoes, clothing, tools, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .phone: "Phone"
        case .laptop: "Laptop"
        case .tablet: "Tablet"
        case .smartwatch: "Smartwatch"
        case .headphones: "Headphones"
        case .tv: "TV"
        case .gamingConsole: "Gaming console"
        case .camera: "Camera"
        case .fridge: "Fridge"
        case .washingMachine: "Washing machine"
        case .dishwasher: "Dishwasher"
        case .stove: "Stove / oven"
        case .microwave: "Microwave"
        case .kettle: "Kettle"
        case .vacuum: "Vacuum cleaner"
        case .mattress: "Mattress"
        case .furniture: "Furniture"
        case .car: "Car"
        case .tyres: "Tyres"
        case .carBattery: "Car battery"
        case .bicycle: "Bicycle"
        case .glasses: "Glasses"
        case .shoes: "Shoes"
        case .clothing: "Clothing"
        case .tools: "Tools"
        case .other: "Other"
        }
    }

    /// Typical lifespan in months.
    var typicalLifespanMonths: Int {
        switch self {
        case .phone: 36
        case .laptop: 60
        case .tablet: 48
        case .smartwatch: 36
        case .headphones: 36
        case .tv: 84
        case .gamingConsole: 72
        case .camera: 72
        case .fridge: 144
        case .washingMachine: 120
        case .dishwasher: 120
        case .stove: 180
        case .microwave: 96
        case .kettle: 48
        case .vacuum: 84
        case .mattress: 96
        case .furniture: 120
        case .car: 120
        case .tyres: 48
        case .carBattery: 48
        case .bicycle: 96
        case .glasses: 24
        case .shoes: 12
        case .clothing: 36
        case .tools: 120
        case .other: 60
        }
    }

    var systemImage: String {
        switch self {
        case .phone: "iphone"
        case .laptop: "laptopcomputer"
        case .tablet: "ipad"
        case .smartwatch: "applewatch"
        case .headphones: "headphones"
        case .tv: "tv"
        case .gamingConsole: "gamecontroller"
        case .camera: "camera"
        case .fridge: "refrigerator"
        case .washingMachine: "washer"
        case .dishwasher: "dishwasher"
        case .stove: "oven"
        case .microwave: "microwave"
        case .kettle: "cup.and.saucer"
        case .vacuum: "fan"
        case .mattress: "bed.double"
        case .furniture: "sofa"
        case .car: "car"
        case .tyres: "circle.circle"
        case .carBattery: "minus.plus.batteryblock"
        case .bicycle: "bicycle"
        case .glasses: "eyeglasses"
        case .shoes: "shoeprints.fill"
        case .clothing: "tshirt"
        case .tools: "wrench.and.screwdriver"
        case .other: "shippingbox"
        }
    }
}
