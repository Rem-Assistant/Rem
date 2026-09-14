import SwiftUI

public struct TaskEventRowSkeleton: View {
    private var timeIndicatorWidth: CGFloat {
        TimeIndicatorWidthCalculator.shared.width
    }

    public init() {}

    public var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            leftIndicatorSkeleton
                .frame(width: timeIndicatorWidth, alignment: .leading)

            contentSkeleton

            Spacer()
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var leftIndicatorSkeleton: some View {
        Text("-")
            .font(.title2)
            .foregroundColor(.clear)
            .frame(maxWidth: .infinity, alignment: .center)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Color.labelSecondary.opacity(0.2))
                    .frame(width: 40, height: 24)
            )
            .shimmering()
    }

    @ViewBuilder
    private var contentSkeleton: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignTokens.Color.labelSecondary.opacity(0.2))
                        .frame(width: 28, height: 28)
                        .shimmering()

                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Color.labelSecondary.opacity(0.2))
                            .frame(width: 180, height: 16)
                            .shimmering()

                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Color.labelSecondary.opacity(0.2))
                            .frame(width: 140, height: 16)
                            .shimmering()
                    }
                }

                HStack(spacing: DesignTokens.Spacing.xs) {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xlarge)
                        .fill(DesignTokens.Color.labelSecondary.opacity(0.2))
                        .frame(width: 80, height: 24)
                        .shimmering()

                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xlarge)
                        .fill(DesignTokens.Color.labelSecondary.opacity(0.2))
                        .frame(width: 60, height: 24)
                        .shimmering()
                }
            }
        }
    }
}
