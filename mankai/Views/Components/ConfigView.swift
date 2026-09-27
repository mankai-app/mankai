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
                case .boolean: BooleanConfigView(configurable: configurable, config: config)
                case .select: SelectConfigView(configurable: configurable, config: config)
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

private struct TextConfigView: View {
    let configurable: any Configurable
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
            .onReceive(configurable.objectWillChange) { updateTextValue() }
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

private struct NumberConfigView: View {
    let configurable: any Configurable
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
            .onReceive(configurable.objectWillChange) { updateNumberValue() }
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

private struct BooleanConfigView: View {
    let configurable: any Configurable
    let config: Config

    @State private var boolValue: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        Toggle(isOn: $boolValue) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(config.name))
                if let description = config.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { updateBoolValue() }
        .onReceive(configurable.objectWillChange) { updateBoolValue() }
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

private struct SelectConfigView: View {
    let configurable: any Configurable
    let config: Config

    @State private var selectedValue: String? = nil
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var options: [String] { config.options ?? [] }

    var body: some View {
        Group {
            if selectedValue != nil {
                Picker(selection: $selectedValue) {
                    ForEach(options, id: \.self) { option in Text(option).tag(option) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(config.name))
                        if let description = config.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
            } else {
                Spacer(minLength: 0)
            }
        }
        .onAppear { updateSelectedValue() }
        .onReceive(configurable.objectWillChange) { updateSelectedValue() }
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
