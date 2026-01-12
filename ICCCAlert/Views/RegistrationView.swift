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
                // Modern gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.1, green: 0.2, blue: 0.45),
                        Color(red: 0.05, green: 0.35, blue: 0.85)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Background decoration
                GeometryReader { geometry in
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 280, height: 280)
                        .offset(x: -80, y: -50)
                        .blur(radius: 40)
                    
                    Circle()
                        .fill(Color.blue.opacity(0.08)) // Changed from .cyan
                        .frame(width: 220, height: 220)
                        .offset(x: geometry.size.width - 100, y: geometry.size.height - 120)
                        .blur(radius: 50)
                }
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Header Section
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color.white.opacity(0.25),
                                                Color.white.opacity(0.1)
                                            ]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 90, height: 90)
                                    .shadow(color: Color.black.opacity(0.1), radius: 15, x: 0, y: 8)
                                
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 44))
                                    .foregroundColor(.white) // Changed from foregroundStyle
                            }
                            
                            VStack(spacing: 6) {
                                Text(step == .details ? "Join ICCC Alert" : "Verify Account")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Text(step == .details ? "Create your account" : "Confirm your number")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                        .padding(.top, 40)
                        .padding(.bottom, 32)
                        
                        // Main Card
                        VStack(spacing: 0) {
                            // Progress Bar
                            HStack(spacing: 10) {
                                ForEach(0..<2) { index in
                                    Capsule()
                                        .fill(
                                            index == 0 && step == .details || index == 1 && step == .otp ?
                                            LinearGradient(
                                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ) :
                                            LinearGradient(
                                                colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.3)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(height: 4)
                                        .animation(.spring(response: 0.4), value: step)
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.top, 24)
                            .padding(.bottom, 32)
                            
                            if step == .details {
                                registrationForm
                            } else {
                                otpVerificationForm
                            }
                            
                            // Error Message
                            if !errorMessage.isEmpty {
                                HStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 16))
                                    Text(errorMessage)
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.red.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                                        )
                                )
                                .padding(.horizontal, 28)
                                .padding(.bottom, 20)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 30)
                                .fill(Color(.systemBackground))
                                .shadow(color: Color.black.opacity(0.15), radius: 30, x: 0, y: 15)
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                    Text("Close")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                )
            })
        }
    }
    
    var registrationForm: some View {
        VStack(spacing: 24) {
            // Section: Personal Information
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                    Text("Personal Information")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 28)
                
                // Name Field
                VStack(alignment: .leading, spacing: 8) {
                    Text("FULL NAME")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 14) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue.opacity(0.7))
                            .frame(width: 24)
                        
                        TextField("", text: $name)
                            .placeholder(when: name.isEmpty) {
                                Text("Enter your full name")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .font(.system(size: 16))
                            .textContentType(.name)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(!name.isEmpty ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )
                }
                .padding(.horizontal, 28)
                
                // Phone Field
                VStack(alignment: .leading, spacing: 8) {
                    Text("MOBILE NUMBER")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Text("🇮🇳")
                                .font(.system(size: 18))
                            Text("+91")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(Color(.systemGray5))
                        .cornerRadius(10)
                        
                        TextField("", text: $phone)
                            .placeholder(when: phone.isEmpty) {
                                Text("10-digit number")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .keyboardType(.phonePad)
                            .font(.system(size: 16, weight: .medium))
                            .textContentType(.telephoneNumber)
                            .onChange(of: phone) { newValue in
                                if newValue.count > 10 {
                                    phone = String(newValue.prefix(10))
                                }
                            }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(phone.count == 10 ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )
                }
                .padding(.horizontal, 28)
            }
            
            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            
            // Section: Work Information
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "building.2")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                    Text("Work Information")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 28)
                
                // Area Field
                VStack(alignment: .leading, spacing: 8) {
                    Text("AREA / LOCATION")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 14) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue.opacity(0.7))
                            .frame(width: 24)
                        
                        TextField("", text: $area)
                            .placeholder(when: area.isEmpty) {
                                Text("Work area or location")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .font(.system(size: 16))
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(!area.isEmpty ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )
                }
                .padding(.horizontal, 28)
                
                // Designation Field
                VStack(alignment: .leading, spacing: 8) {
                    Text("DESIGNATION")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 14) {
                        Image(systemName: "briefcase.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue.opacity(0.7))
                            .frame(width: 24)
                        
                        TextField("", text: $designation)
                            .placeholder(when: designation.isEmpty) {
                                Text("Your job title")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .font(.system(size: 16))
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(!designation.isEmpty ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )
                }
                .padding(.horizontal, 28)
                
                // Organisation Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("ORGANISATION")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 0) {
                        ForEach(organisations, id: \.self) { org in
                            Button(action: {
                                withAnimation(.spring(response: 0.3)) {
                                    organisation = org
                                }
                            }) {
                                Text(org)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(organisation == org ? .white : .primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        organisation == org ?
                                        LinearGradient(
                                            colors: [Color.blue, Color.blue.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ) :
                                        LinearGradient(
                                            colors: [Color(.systemGray6), Color(.systemGray6)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(org == organisations.first ? 12 : 0, corners: [.topLeft, .bottomLeft])
                                    .cornerRadius(org == organisations.last ? 12 : 0, corners: [.topRight, .bottomRight])
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 28)
            }
            
            // Continue Button
            Button(action: register) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        HStack(spacing: 10) {
                            Text("Continue")
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 20))
                        }
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Group {
                        if !isFormValid || isLoading {
                            Color.gray.opacity(0.5)
                        } else {
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.05, green: 0.35, blue: 0.85),
                                    Color(red: 0.1, green: 0.45, blue: 0.95)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                    }
                )
                .cornerRadius(16)
                .shadow(
                    color: isFormValid && !isLoading ? Color.blue.opacity(0.4) : .clear,
                    radius: 12,
                    x: 0,
                    y: 6
                )
            }
            .disabled(!isFormValid || isLoading)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }
    
    var otpVerificationForm: some View {
        VStack(spacing: 28) {
            // Success Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.15), Color.green.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green) // Changed from foregroundStyle
                    .shadow(color: Color.green.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .padding(.top, 20)
            
            VStack(spacing: 10) {
                Text("Verify Your Number")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("We've sent a code to")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                
                Text("+91 \(phone)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.blue)
            }
            
            // OTP Input
            VStack(alignment: .leading, spacing: 10) {
                Text("VERIFICATION CODE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 24)
                    
                    TextField("", text: $otp)
                        .placeholder(when: otp.isEmpty) {
                            Text("Enter 6-digit code")
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .onChange(of: otp) { newValue in
                            if newValue.count > 6 {
                                otp = String(newValue.prefix(6))
                            }
                        }
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 18)
                .background(Color(.systemGray6))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(otp.count == 6 ? Color.green : Color.blue.opacity(0.3), lineWidth: 2)
                )
            }
            .padding(.horizontal, 28)
            
            // Verify Button
            Button(action: verifyOTP) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                            Text("Verify & Complete")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Group {
                        if otp.count != 6 || isLoading {
                            Color.gray.opacity(0.5)
                        } else {
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.05, green: 0.35, blue: 0.85),
                                    Color(red: 0.1, green: 0.45, blue: 0.95)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                    }
                )
                .cornerRadius(16)
                .shadow(
                    color: otp.count == 6 && !isLoading ? Color.blue.opacity(0.4) : .clear,
                    radius: 12,
                    x: 0,
                    y: 6
                )
            }
            .disabled(otp.count != 6 || isLoading)
            .padding(.horizontal, 28)
            
            // Change Details Button
            Button(action: {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    step = .details
                    otp = ""
                    errorMessage = ""
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                    Text("Change Details")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.blue)
                .padding(.vertical, 12)
            }
            
            Spacer()
                .frame(height: 20)
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
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
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

// Helper for selective corner radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

struct RegistrationView_Previews: PreviewProvider {
    static var previews: some View {
        RegistrationView()
            .environmentObject(AuthManager.shared)
    }
}