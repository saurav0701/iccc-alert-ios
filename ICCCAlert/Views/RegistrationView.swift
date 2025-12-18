import SwiftUI

struct RegistrationView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var name = ""
    @State private var phone = ""
    @State private var area = ""
    @State private var designation = ""
    @State private var organisation = "CCL"
    @State private var otp = ""
    
    @State private var step: RegistrationStep = .details
    @State private var errorMessage = ""
    @State private var isLoading = false
    
    enum RegistrationStep {
        case details
        case otp
    }
    
    let organisations = ["CCL", "BCCL"]
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.05, green: 0.4, blue: 0.95),
                        Color(red: 0.1, green: 0.5, blue: 1.0)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 0) {
                        // Header
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(width: 80, height: 80)
                                
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white)
                            }
                            
                            Text("Create Account")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                            
                            Text("Join ICCC Alert System")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.top, 40)
                        .padding(.bottom, 30)
                        
                        // Main Card
                        VStack(spacing: 24) {
                            // Progress Indicator
                            HStack(spacing: 12) {
                                ForEach(0..<2) { index in
                                    Capsule()
                                        .fill(index == 0 && step == .details || index == 1 && step == .otp ? 
                                            Color.blue : Color.gray.opacity(0.3))
                                        .frame(height: 4)
                                }
                            }
                            .padding(.horizontal)
                            
                            if step == .details {
                                registrationForm
                            } else {
                                otpVerificationForm
                            }
                            
                            if !errorMessage.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                    Text(errorMessage)
                                        .font(.caption)
                                }
                                .foregroundColor(.red)
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.red.opacity(0.1))
                                )
                            }
                        }
                        .padding(28)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(.systemBackground))
                                .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Cancel")
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                    )
                }
            )
        }
    }
    
    var registrationForm: some View {
        VStack(spacing: 20) {
            Text("Personal Information")
                .font(.headline)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Name Field
            VStack(alignment: .leading, spacing: 8) {
                Label("Full Name", systemImage: "person.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                TextField("Enter your full name", text: $name)
                    .textContentType(.name)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            }
            
            // Phone Field
            VStack(alignment: .leading, spacing: 8) {
                Label("Phone Number", systemImage: "phone.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Text("+91")
                        .foregroundColor(.primary)
                        .padding(.leading, 4)
                    
                    Divider()
                        .frame(height: 24)
                    
                    TextField("10-digit mobile number", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .onChange(of: phone) { newValue in
                            if newValue.count > 10 {
                                phone = String(newValue.prefix(10))
                            }
                        }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
            }
            
            Divider()
                .padding(.vertical, 4)
            
            Text("Work Information")
                .font(.headline)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Area Field
            VStack(alignment: .leading, spacing: 8) {
                Label("Area", systemImage: "location.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                TextField("Work area/location", text: $area)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            }
            
            // Designation Field
            VStack(alignment: .leading, spacing: 8) {
                Label("Designation", systemImage: "briefcase.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                TextField("Your job title", text: $designation)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            }
            
            // Organisation Picker
            VStack(alignment: .leading, spacing: 8) {
                Label("Organisation", systemImage: "building.2.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Picker("Organisation", selection: $organisation) {
                    ForEach(organisations, id: \.self) { org in
                        Text(org).tag(org)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.vertical, 4)
            }
            
            // Continue Button
            Button(action: register) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Continue")
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: isFormValid && !isLoading ?
                            [Color(red: 0.05, green: 0.4, blue: 0.95), Color(red: 0.1, green: 0.5, blue: 1.0)] :
                            [Color.gray, Color.gray]
                        ),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(color: isFormValid && !isLoading ? Color.blue.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
            }
            .disabled(!isFormValid || isLoading)
            .padding(.top, 8)
        }
    }
    
    var otpVerificationForm: some View {
        VStack(spacing: 24) {
            // Success Icon
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
            }
            
            VStack(spacing: 8) {
                Text("Verify Your Number")
                    .font(.title3)
                    .fontWeight(.bold)
                
                Text("OTP sent to +91 \(phone)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // OTP Input
            VStack(alignment: .leading, spacing: 8) {
                Label("One-Time Password", systemImage: "lock.shield.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                TextField("Enter 6-digit OTP", text: $otp)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 24, weight: .semibold))
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.5), lineWidth: 2)
                    )
                    .onChange(of: otp) { newValue in
                        if newValue.count > 6 {
                            otp = String(newValue.prefix(6))
                        }
                    }
            }
            
            // Verify Button
            Button(action: verifyOTP) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "checkmark.shield.fill")
                        Text("Verify & Complete")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: otp.count == 6 && !isLoading ?
                            [Color(red: 0.05, green: 0.4, blue: 0.95), Color(red: 0.1, green: 0.5, blue: 1.0)] :
                            [Color.gray, Color.gray]
                        ),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(color: otp.count == 6 && !isLoading ? Color.blue.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
            }
            .disabled(otp.count != 6 || isLoading)
            
            // Change Details Button
            Button(action: {
                withAnimation(.spring()) {
                    step = .details
                    otp = ""
                    errorMessage = ""
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.caption)
                    Text("Change Details")
                        .fontWeight(.medium)
                }
                .foregroundColor(.blue)
            }
        }
    }
    
    var isFormValid: Bool {
        !name.isEmpty &&
        phone.count == 10 &&
        !area.isEmpty &&
        !designation.isEmpty
    }
    
    func register() {
        isLoading = true
        errorMessage = ""
        
        authManager.registerUser(
            name: name,
            phone: phone,
            area: area,
            designation: designation,
            organisation: organisation
        ) { success, message in
            isLoading = false
            if success {
                withAnimation(.spring()) {
                    step = .otp
                }
            } else {
                errorMessage = message
            }
        }
    }
    
    func verifyOTP() {
        isLoading = true
        errorMessage = ""
        
        authManager.verifyRegistrationOTP(phone: phone, otp: otp) { success, message in
            isLoading = false
            if success {
                presentationMode.wrappedValue.dismiss()
            } else {
                errorMessage = message
            }
        }
    }
}

struct RegistrationView_Previews: PreviewProvider {
    static var previews: some View {
        RegistrationView()
            .environmentObject(AuthManager.shared)
    }
}