import SwiftUI

struct RegistrationView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
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
            ScrollView {
                VStack(spacing: 25) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("Register New Account")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .padding(.top, 20)
                    
                    if step == .details {
                        registrationForm
                    } else {
                        otpVerificationForm
                    }
                    
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    var registrationForm: some View {
        VStack(spacing: 20) {
            // Name
            VStack(alignment: .leading, spacing: 8) {
                Text("Full Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField("Enter your full name", text: $name)
                    .textContentType(.name)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }
            
            // Phone
            VStack(alignment: .leading, spacing: 8) {
                Text("Phone Number")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Text("+91")
                        .foregroundColor(.secondary)
                    TextField("10-digit phone", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }
            
            // Area
            VStack(alignment: .leading, spacing: 8) {
                Text("Area")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField("Work area/location", text: $area)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }
            
            // Designation
            VStack(alignment: .leading, spacing: 8) {
                Text("Designation")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField("Your job title", text: $designation)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }
            
            // Organisation
            VStack(alignment: .leading, spacing: 8) {
                Text("Organisation")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("Organisation", selection: $organisation) {
                    ForEach(organisations, id: \.self) { org in
                        Text(org).tag(org)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Button(action: register) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Continue")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isFormValid ? Color.blue : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(!isFormValid || isLoading)
        }
    }
    
    var otpVerificationForm: some View {
        VStack(spacing: 20) {
            Text("OTP sent to +91 \(phone)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter OTP")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField("6-digit OTP", text: $otp)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }
            
            Button(action: verifyOTP) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Verify & Complete Registration")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(otp.count == 6 ? Color.blue : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(otp.count != 6 || isLoading)
            
            Button(action: {
                step = .details
                otp = ""
                errorMessage = ""
            }) {
                Text("Change Details")
                    .font(.subheadline)
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
                step = .otp
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
                dismiss()
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