//
//  ConfigView.swift
//  mankai
//
//  Created by Travis XU on 27/9/2026.
//

import Combine
import SwiftUI

struct ConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    @ObservedObject var configurable: ConfigurableObject

    var body: some View {
        ForEach(configurable.configs, id: \.key) { config in
            switch config.type { case .text:
                TextConfigView(configurable: configurable, config: config)
                case .password:
                    TextConfigView(configurable: configurable, config: config, isPassword: true)
                case .number: NumberConfigView(configurable: configurable, config: config)
                case .slider: SliderConfigView(configurable: configurable, config: config)
                case .boolean: BooleanConfigView(configurable: configurable, config: config)
                case .select: SelectConfigView(configurable: configurable, config: config)
                case .color: ColorConfigView(configurable: configurable, config: config)
            }
        }
    }
}

private struct ConfigTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.padding(.horizontal).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .foregroundColor(.primary)
    }
}

private struct TextConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    let configurable: ConfigurableObject
    let config: Config
    var isPassword: Bool = false

    @State private var textValue: String = ""
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                Text(LocalizedStringKey(config.name))

                if let description = config.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }

            Group {
                if isPassword {
                    SecureField(LocalizedStringKey(config.type.rawValue), text: $textValue)
                        .textContentType(.password)
                } else {
                    TextField(LocalizedStringKey(config.type.rawValue), text: $textValue)
                }
            }
            .textFieldStyle(ConfigTextFieldStyle()).autocapitalization(.none)
            .onAppear { updateTextValue() }
            .onReceive(configurable.objectWillChange) { _ in updateTextValue() }
            .onChange(of: textValue, initial: false) { _, newValue in
                do { try configurable.setConfig(key: config.key, value: newValue) } catch {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
        .alert("failedToSetConfigValue", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func updateTextValue() {
        let newValue =
            configurable.getConfig(config.key) as? String ?? config.defaultValue as? String ?? ""
        if textValue != newValue { textValue = newValue }
    }
}

private struct SliderConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    let configurable: ConfigurableObject
    let config: Config

    @State private var sliderValue: Double = 0
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var range: ClosedRange<Double> {
        let lowerBound = config.min ?? 0
        let upperBound = config.max ?? 1
        if lowerBound < upperBound { return lowerBound...upperBound }
        if upperBound < lowerBound { return upperBound...lowerBound }
        return lowerBound...(lowerBound + 1)
    }

    private var step: Double {
        guard let step = config.step, step > 0 else { return 1 }
        return step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(config.name))
                Spacer()
                Text(sliderValue, format: .number).foregroundStyle(.secondary)
            }

            Slider(value: $sliderValue, in: range, step: step).onAppear { updateSliderValue() }
                .onReceive(configurable.objectWillChange) { _ in updateSliderValue() }
                .onChange(of: sliderValue, initial: false) { _, newValue in
                    do { try configurable.setConfig(key: config.key, value: newValue) } catch {
                        errorMessage = error.localizedDescription
                        showErrorAlert = true
                    }
                }

            if let description = config.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("failedToSetConfigValue", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func updateSliderValue() {
        var newValue: Double
        if let value = configurable.getConfig(config.key) as? Double {
            newValue = value
        } else if let value = configurable.getConfig(config.key) as? Int {
            newValue = Double(value)
        } else if let value = config.defaultValue as? Double {
            newValue = value
        } else if let value = config.defaultValue as? Int {
            newValue = Double(value)
        } else {
            newValue = range.lowerBound
        }

        newValue = min(max(newValue, range.lowerBound), range.upperBound)
        if sliderValue != newValue { sliderValue = newValue }
    }
}

private struct NumberConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    let configurable: ConfigurableObject
    let config: Config

    @State private var numberValue: Double = 0
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                Text(LocalizedStringKey(config.name))

                if let description = config.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField(
                LocalizedStringKey(config.type.rawValue), value: $numberValue, format: .number
            )
            .textFieldStyle(ConfigTextFieldStyle()).keyboardType(.decimalPad)
            .onAppear { updateNumberValue() }
            .onReceive(configurable.objectWillChange) { _ in updateNumberValue() }
            .onChange(of: numberValue, initial: false) { _, newValue in
                do { try configurable.setConfig(key: config.key, value: newValue) } catch {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
        .alert("failedToSetConfigValue", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func updateNumberValue() {
        var newValue: Double = 0
        if let value = configurable.getConfig(config.key) as? Double {
            newValue = value
        } else if let value = configurable.getConfig(config.key) as? Int {
            newValue = Double(value)
        } else if let value = config.defaultValue as? Double {
            newValue = value
        } else if let value = config.defaultValue as? Int {
            newValue = Double(value)
        }

        if numberValue != newValue { numberValue = newValue }
    }
}

private struct BooleanConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    let configurable: ConfigurableObject
    let config: Config

    @State private var boolValue: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(LocalizedStringKey(config.name), isOn: $boolValue)

            if let description = config.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { updateBoolValue() }
        .onReceive(configurable.objectWillChange) { _ in updateBoolValue() }
        .onChange(of: boolValue, initial: false) { _, newValue in
            do { try configurable.setConfig(key: config.key, value: newValue) } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
        .alert("failedToSetConfigValue", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func updateBoolValue() {
        let newValue =
            configurable.getConfig(config.key) as? Bool ?? config.defaultValue as? Bool ?? false
        if boolValue != newValue { boolValue = newValue }
    }
}

private struct SelectConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    let configurable: ConfigurableObject
    let config: Config

    @State private var selectedValue: String? = nil
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var options: [String] { config.options ?? [] }

    var body: some View {
        Group {
            if selectedValue != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(selection: $selectedValue) {
                        ForEach(options, id: \.self) { option in
                            Text(LocalizedStringKey(option)).tag(option)
                        }
                    } label: {
                        Text(LocalizedStringKey(config.name))
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedValue, initial: false) { _, newValue in
                        do {
                            if let newValue {
                                try configurable.setConfig(key: config.key, value: newValue)
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                            showErrorAlert = true
                        }
                    }

                    if let description = config.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .onAppear { updateSelectedValue() }
        .onReceive(configurable.objectWillChange) { _ in updateSelectedValue() }
        .alert("failedToSetConfigValue", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func updateSelectedValue() {
        var newValue =
            configurable.getConfig(config.key) as? String ?? config.defaultValue as? String ?? ""

        if !options.contains(newValue), !options.isEmpty { newValue = options.first ?? "" }

        if selectedValue != newValue { selectedValue = newValue }
    }
}

private struct ColorConfigView<ConfigurableObject: Configurable & ObservableObject>: View {
    @ObservedObject var configurable: ConfigurableObject
    let config: Config

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var selectedColor: Color {
        let storedColor = (configurable.getConfig(config.key) as? String).flatMap { Color(hex: $0) }
        let defaultColor = (config.defaultValue as? String).flatMap { Color(hex: $0) }
        return storedColor ?? defaultColor ?? .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColorPicker(
                selection: Binding(
                    get: { selectedColor },
                    set: { newValue in
                        guard
                            let hex = newValue.hex(includingAlpha: config.supportsOpacity ?? false)
                        else { return }
                        do { try configurable.setConfig(key: config.key, value: hex) } catch {
                            errorMessage = error.localizedDescription
                            showErrorAlert = true
                        }
                    }), supportsOpacity: config.supportsOpacity ?? false
            ) { Text(LocalizedStringKey(config.name)) }

            if let description = config.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("failedToSetConfigValue", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }
}
